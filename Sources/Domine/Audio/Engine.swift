import CoreAudio
import DomineDSP
import Observation
import os

/// Owns the tap, the private aggregate, the IOProc, and the render kernel
/// (SPEC sections 3.2 and 7).
///
/// Start: validate devices, match rates (speakers keep their own; see
/// matchSpeakerRates), set the default output to Device A's rate and wait for
/// it to take effect, create the tap (rebuilt once if it still came up at the
/// old rate), create the aggregate, read its stream layout, create the kernel
/// and store the layout in it, create the IOProc, start the device, log the
/// signal chain. Any failure unwinds what was created, in reverse, and ends
/// in `.error`.
/// Speakers coming and going (SPEC section 7): while routing, the engine
/// watches the device list and each speaker's IsAlive, by UID. When the set
/// of present speakers changes it fades out over 50 ms, tears everything
/// down, and builds a fresh tap and aggregate for the speakers that are
/// left, fading back in: one speaker is `.degraded(.monoFallback)`, both
/// are `.running`, none stops the engine (`onRoutingEnded`).
/// Stop: stop the device, destroy the IOProc, the aggregate, the tap, and
/// last the kernel, once no IOProc can call into it.
@MainActor
@Observable
final class Engine {
    static let kernelMaxFrames: UInt32 = 4096

    private(set) var state: EngineState = .idle
    /// Set when a start request was refused and the engine stayed idle.
    private(set) var idleReason: IdleReason?
    /// The layout of the running aggregate.
    private(set) var layout: AggregateLayout?

    // Kernel controls. They apply immediately while running and to the next start.
    var swapSides = false {
        didSet {
            guard swapSides != oldValue else { return }
            Self.log.info("Swap sides \(self.swapSides ? "on" : "off", privacy: .public): left plays on position \(self.swapSides ? "B" : "A", privacy: .public), kernel \(self.resources.kernel != nil ? "live" : "not allocated", privacy: .public)")
            applyControls()
        }
    }
    var testTone: TestTone = .off { didSet { applyControls() } }
    /// Clicks on both speakers through the delay line, to line them up by
    /// ear. Every stop turns it off.
    var clickTest = false { didSet { if clickTest != oldValue { applyControls() } } }
    /// Calibration chirps (click test mode 2, SPEC section 12): rising on the
    /// left, falling on the right, once a second. Wins over `clickTest`.
    /// Every stop turns it off.
    var calibrationChirps = false { didSet { if calibrationChirps != oldValue { applyControls() } } }
    var leftGain: Float = 1 { didSet { applyControls() } }
    var rightGain: Float = 1 { didSet { applyControls() } }
    /// Positive delays the right speaker, negative the left (SPEC section 4).
    var delayMs: Float = 0 { didSet { applyControls() } }
    /// Effects per physical speaker: position A (Front Left device) and B.
    /// Positions never swap, so Swap Sides does not move them.
    private(set) var effectsA = PairSettings.SideEffects()
    private(set) var effectsB = PairSettings.SideEffects()
    /// Test hook: the last EQ parameters pushed to the kernel for position A and B.
    private(set) var pushedEQ: [DomineEQParams] = []
    func setEffects(left: PairSettings.SideEffects, right: PairSettings.SideEffects) {
        guard left != effectsA || right != effectsB else { return }
        effectsA = left
        effectsB = right
        applyControls()
    }
    /// Fades the output out (or back in) over 50 ms in the kernel.
    var muted = false { didSet { applyControls() } }
    /// Called when the engine stops routing on its own: both speakers
    /// disconnected, or a rebuild failed. The caller restores the output.
    @ObservationIgnored var onRoutingEnded: (@MainActor () -> Void)?
    /// The running speaker check, so tests can wait for it.
    @ObservationIgnored private(set) var speakerCheck: Task<Void, Never>?
    let monoPerSpeaker = true
    /// Process objects the next tap leaves out besides Domine itself
    /// (SPEC 3b). Empty until excluded apps are resolved to processes.
    var excludedProcesses: [AudioObjectID] = []
    /// Apps with a reduced volume, each on its own muting tap (per-app volume).
    /// Sorted by key, capped at `maxAppTaps`.
    private(set) var appTapRequests: [AppTapRequest] = []
    /// Wait before a changed app set rebuilds, so a burst causes one rebuild.
    @ObservationIgnored var appTapDebounce: Duration = .milliseconds(500)
    @ObservationIgnored private(set) var appTapRebuild: Task<Void, Never>?
    static let maxAppTaps = 7

    // Surround controls (SPEC 13). They apply live to a running surround kernel.
    /// The surround set in list order: positions move live (VBAP and
    /// distance compensation follow), matched to the routed speakers by UID.
    var surroundSpeakers: [SurroundSpeaker] = [] { didSet { applyControls() } }
    /// Azimuth of the L and R sources, degrees (kernel clamps 10...90).
    var surroundWidth: Float = 30 { didSet { applyControls() } }
    /// Ambience level 0...1.
    var surroundLevel: Float = 0.7 { didSet { applyControls() } }
    /// L and R summed before panning (Sound sheet, Surround).
    var surroundMono = false { didSet { if surroundMono != oldValue { applyControls() } } }
    /// Orbit speed in degrees per second; going back to 0 resets the phase.
    var orbitRate: Float = 0 {
        didSet {
            if orbitRate == 0, oldValue != 0, let surround = resources.surround { domine_surround_reset_orbit(surround) }
            applyControls()
        }
    }
    /// Static rotation of the field, degrees.
    var rotation: Float = 0 { didSet { applyControls() } }
    /// Spatial upmixer (ambience) parameters: amount 0...1, room 5...30 ms.
    var spatialAmount: Float = 0.6 { didSet { applyControls() } }
    var spatialRoomMs: Float = 15 { didSet { applyControls() } }
    /// Trim gain per speaker UID, 0...1, master volume included. Missing is 1.
    var surroundGains: [String: Float] = [:] { didSet { applyControls() } }
    /// Calibration offset per speaker UID in ms, added to distance delay
    /// unless `surroundTimingMeasured`. Missing is 0.
    var surroundDelaysMs: [String: Float] = [:] { didSet { applyControls() } }
    /// The offsets were measured with the microphone (SPEC 13.4): they
    /// already include acoustic travel, so distance sets level only.
    var surroundTimingMeasured = false { didSet { if surroundTimingMeasured != oldValue { applyControls() } } }
    /// Surround calibration chirps (SPEC 12): kernel speaker indexes (list
    /// order) of the rising and falling speaker; nil is off. Every stop turns it off.
    var surroundCalibrationPair: SurroundCalibrationPair? = nil {
        didSet { if surroundCalibrationPair != oldValue { applyControls() } }
    }
    struct SurroundCalibrationPair: Equatable, Sendable {
        var rising: Int
        var falling: Int
    }
    /// Effects per speaker UID, already resolved (linking) by the caller.
    private(set) var surroundEffects: [String: PairSettings.SideEffects] = [:]
    func setSurroundEffects(_ effects: [String: PairSettings.SideEffects]) {
        guard effects != surroundEffects else { return }
        surroundEffects = effects
        applyControls()
    }
    /// The surround speaker playing the chime test tone, by UID; nil is off.
    var surroundTestTone: String? = nil { didSet { if surroundTestTone != oldValue { applyControls() } } }
    /// The UIDs of a surround routing in list order; nil in stereo.
    @ObservationIgnored fileprivate(set) var surroundRoute: [String]?
    /// Surround routing: the speakers in this build, in list order, with
    /// their kernel indexes (for `surroundCalibrationPair`). Empty in stereo
    /// and during the stereo demo.
    var surroundPresentSpeakers: [(uid: String, index: Int)] {
        guard surroundRoute != nil, !stereoDemo, resources.surround != nil else { return [] }
        let uids = resources.surroundUIDs
        let present = resources.surroundPresent
        var speakers: [(uid: String, index: Int)] = []
        for index in uids.indices where index < present.count && present[index] {
            speakers.append((uid: uids[index], index: index))
        }
        return speakers
    }
    /// Test hook: what the last control push gave the surround kernel, per
    /// kernel index (list order; the stereo demo uses A, B).
    private(set) var pushedSurround: PushedSurround?
    struct PushedSurround: Equatable, Sendable {
        var azimuths: [Float]
        var gains: [Float]
        var delaysMs: [Float]
        var width: Float
        var rotation: Float
        var orbitRate: Float
    }

    // Demo (SPEC 14).
    /// A demo was asked for and has not ended.
    private(set) var demoRequested = false
    /// Stereo routing plays the demo through the surround kernel (SPEC 14.4).
    @ObservationIgnored private(set) var stereoDemo = false
    @ObservationIgnored fileprivate var startStereoDemo = false
    @ObservationIgnored fileprivate var demoWatch: Task<Void, Never>?
    /// How often the engine checks whether the demo finished.
    @ObservationIgnored var demoPollInterval: Duration = .milliseconds(100)
    /// A demo that never reports playing within this time counts as finished
    /// (the IOProc is not running).
    @ObservationIgnored var demoStartGrace: Duration = .seconds(2)

    var isKernelAllocated: Bool { resources.kernel != nil || resources.surround != nil }

    /// The rate the kernel was created with (the aggregate's nominal rate).
    var kernelSampleRate: Double? {
        guard let kernel = resources.kernel else { return resources.surround != nil ? resources.surroundRate : nil }
        var stats = DomineKernelStats()
        _ = domine_kernel_stats(kernel, &stats)
        return stats.sampleRate
    }

    private struct Resources {
        var tap: ProcessTap?
        /// Per-app taps in aggregate order, by app key.
        var appTaps: [(key: String, tap: ProcessTap)] = []
        var aggregate: AudioObjectID?
        var kernel: OpaquePointer?
        var surround: OpaquePointer?
        /// Surround: the UIDs at each kernel index (the route, or A and B
        /// for the stereo demo) and whether each is in this build.
        var surroundUIDs: [String] = []
        var surroundPresent: [Bool] = []
        /// The surround kernel's rate (the aggregate's nominal rate).
        var surroundRate: Double?
        /// Surround route: the device ID per speaker; nil for one left out.
        var surroundIDs: [AudioObjectID?] = []
        var ioProc: IOProcHandle?
        var deviceStarted = false
        /// The default output's rate before Domine matched it (restored on stop).
        var defaultRateRestore: (uid: String, rate: Double)?
        var diagnostics: EngineDiagnostics?
        var watchTokens: [HALListenerToken] = []
        /// What the tap delivered at start, to notice a change while running.
        var tapFormat: AudioStreamBasicDescription?
        var defaultOutputUID: String?
        /// The speakers' device IDs in the aggregate; nil for one left out.
        var speakerIDs = SpeakerIDs(a: nil, b: nil)
    }

    private struct SpeakerIDs: Equatable {
        var a: AudioObjectID?
        var b: AudioObjectID?
    }

    /// Kernel input format chosen at start (for tests and the log).
    struct InputFormat: Equatable, Sendable {
        let sampleRate: Double
        let channels: UInt32
        let nonInterleaved: Bool
    }

    /// The tap stream format the kernel was told about at the last start.
    private(set) var inputFormat: InputFormat?
    /// The sample rates along the path at the last start (SPEC section 4,
    /// Signal quality).
    private(set) var signalChain: SignalChain?
    /// The running diagnostics, for tests.
    var diagnostics: EngineDiagnostics? { resources.diagnostics }

    private struct SubDevice {
        let uid: String
        let id: AudioObjectID
        let output: [Int]
        let inputBuffers: Int
        /// "A" or "B", for the log and diagnostics.
        let label: String
    }

    private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "Engine")

    @ObservationIgnored private let hal: any AudioHAL
    @ObservationIgnored private let taps: TapController
    @ObservationIgnored private let layoutAttempts: Int
    @ObservationIgnored private let layoutRetryDelay: Duration
    @ObservationIgnored private var resources = Resources()
    /// Bumped by every start and stop, so a start suspended while the
    /// aggregate settles can tell it was cancelled.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let diagnosticsInterval: Duration
    @ObservationIgnored private let formatCheckDelay: Duration
    @ObservationIgnored private let rateSettleAttempts: Int
    @ObservationIgnored private let rateSettlePoll: Duration
    @ObservationIgnored private var speakers: (left: String, right: String)?
    @ObservationIgnored private var formatCheck: Task<Void, Never>?
    /// Rebuilds in a row caused by format changes; capped so a flapping
    /// device cannot rebuild forever.
    @ObservationIgnored private var formatRebuilds = 0
    static let maxFormatRebuilds = 3
    /// The kernel plays (L + R) / 2 because one speaker is left out.
    @ObservationIgnored private var kernelMonoFallback = false
    /// The kernel is fading out before a rebuild.
    @ObservationIgnored private var fadingOut = false
    @ObservationIgnored private var speakerCheckPending = false
    /// Speakers a stereo rebuild failed for; not retried until they change.
    @ObservationIgnored private var refusedSpeakerIDs: SpeakerIDs?
    /// Waits out the kernel's fade before a rebuild. Tests replace it.
    @ObservationIgnored private let fadeWait: @MainActor (Duration) async -> Void
    /// How long a fade out before a rebuild is given: the kernel's 50 ms
    /// ramp plus room for the IO cycle that plays its end.
    static let rebuildFadeWait: Duration = .milliseconds(60)

    /// The aggregate may publish its streams a moment after creation, so the
    /// layout read is retried up to `layoutAttempts` times. A new default
    /// output rate is polled for up to `rateSettleAttempts` times,
    /// `rateSettlePoll` apart (1 s in all by default).
    init(hal: any AudioHAL, layoutAttempts: Int = 10, layoutRetryDelay: Duration = .milliseconds(50),
         diagnosticsInterval: Duration = .seconds(2), formatCheckDelay: Duration = .milliseconds(300),
         rateSettleAttempts: Int = 100, rateSettlePoll: Duration = .milliseconds(10),
         fadeWait: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.hal = hal
        self.taps = TapController(hal: hal)
        self.layoutAttempts = max(1, layoutAttempts)
        self.layoutRetryDelay = layoutRetryDelay
        self.diagnosticsInterval = diagnosticsInterval
        self.formatCheckDelay = formatCheckDelay
        self.rateSettleAttempts = max(1, rateSettleAttempts)
        self.rateSettlePoll = rateSettlePoll
        self.fadeWait = fadeWait
    }

    // MARK: - Start and stop

    func start(left uidA: String?, right uidB: String?) async {
        switch state {
        case .idle, .error: break
        case .starting, .running, .degraded, .stopping: return
        }
        idleReason = nil
        guard let uidA else { return refuse(.noLeftSpeaker) }
        guard let uidB else { return refuse(.noRightSpeaker) }
        guard uidA != uidB else { return refuse(.sameSpeaker) }

        let idA: AudioObjectID, idB: AudioObjectID
        do {
            idA = try hal.deviceID(forUID: uidA)
            idB = try hal.deviceID(forUID: uidB)
        } catch {
            state = .error(EngineError.hal(error).description)
            return
        }
        guard idA != kAudioObjectUnknown else { return refuse(.leftMissing) }
        guard idB != kAudioObjectUnknown else { return refuse(.rightMissing) }

        state = .starting
        generation &+= 1
        refusedSpeakerIDs = nil
        if let error = await build(uidA: uidA, uidB: uidB, ids: SpeakerIDs(a: idA, b: idB), fadeIn: false) {
            state = .error(error.description)
        }
    }

    /// Creates the tap, the aggregate, the kernel, and the IOProc for the
    /// present speakers in `ids` (at least one), and ends in `.running`
    /// (both) or `.degraded(.monoFallback)` (one). Bump `generation` first.
    /// On failure it tears down what it made and returns the error without
    /// changing `state`. A stop while it waits ends it quietly (nil).
    /// `fadeIn` starts the kernel silent so it ramps up over 50 ms.
    private func build(uidA: String, uidB: String, ids: SpeakerIDs, fadeIn: Bool) async -> EngineError? {
        let current = generation
        do throws(EngineError) {
            var a: SubDevice?, b: SubDevice?
            if let id = ids.a { a = try inspect(uid: uidA, id: id, label: "A") }
            if let id = ids.b { b = try inspect(uid: uidB, id: id, label: "B") }
            let present = [a, b].compactMap { $0 }
            guard let main = present.first else { throw .kernelUnavailable }
            if let a, let b { matchSpeakerRates(a: a, b: b) }
            let targetRate = try? hal.nominalSampleRate(of: main.id)
            if let targetRate, matchDefaultOutputRate(speakers: present, target: targetRate) {
                // The tap takes the default output's rate when it is created,
                // so wait for the new rate before creating it.
                if !(await waitForDefaultOutputRate(targetRate)) {
                    Self.log.warning("Default output did not report \(targetRate, privacy: .public) Hz within the wait; creating the tap anyway")
                }
                guard current == generation else { return nil }
            }
            guard try await createTap(expectedRate: targetRate, generation: current) else { return nil }
            try createAggregate(present)
            guard let layout = try await readLayout(a: a, b: b, generation: current),
                  current == generation else { return nil }
            kernelMonoFallback = present.count == 1
            let demo = startStereoDemo && present.count == 2
            startStereoDemo = false
            if stereoDemo && !demo { endDemoState() }
            stereoDemo = demo
            if demo {
                // SPEC 14.4: the pair on the surround kernel, A at -30 and B at +30 (swap applied).
                try startSurroundIO(layout: layout, uids: [uidA, uidB], fadeIn: fadeIn)
                if let surround = resources.surround { domine_surround_set_demo(surround, 1) }
            } else {
                try startIO(layout: layout, fadeIn: fadeIn)
            }
            self.layout = layout
            speakers = (uidA, uidB)
            resources.speakerIDs = ids
            if a == nil {
                state = .degraded(.monoFallback(missing: .left))
            } else if b == nil {
                state = .degraded(.monoFallback(missing: .right))
            } else {
                state = .running
            }
            let summary = present.map { "\($0.label) \($0.uid)" }.joined(separator: ", ")
            Self.log.info("\(self.kernelMonoFallback ? "Mono fallback" : "Running", privacy: .public): \(summary, privacy: .public), layout \(String(describing: layout), privacy: .public)")
            logSignalChain(present)
            startDiagnostics(present)
            watchFormat()
            watchSpeakers()
            return nil
        } catch {
            guard current == generation else { return nil }
            teardown()
            layout = nil
            Self.log.error("Start failed: \(error.description, privacy: .public)")
            return error
        }
    }

    func stop() {
        clickTest = false
        calibrationChirps = false
        surroundCalibrationPair = nil
        formatCheck?.cancel()
        formatCheck = nil
        formatRebuilds = 0
        speakers = nil
        surroundRoute = nil
        surroundTestTone = nil
        startStereoDemo = false
        stereoDemo = false
        endDemoState()
        halt()
    }

    private func halt() {
        if state == .idle && isEmpty(resources) { return }
        generation &+= 1
        state = .stopping
        teardown()
        layout = nil
        idleReason = nil
        state = .idle
    }

    fileprivate func refuse(_ reason: IdleReason) {
        idleReason = reason
        state = .idle
    }

    // MARK: - Start steps

    /// Reads a sub-device's streams. Refuses a Bluetooth device with input
    /// streams, because the aggregate would open that input (SPEC section 9).
    private func inspect(uid: String, id: AudioObjectID, label: String) throws(EngineError) -> SubDevice {
        let (transport, input, output) = try EngineError.hal { () throws(HALError) in
            (try hal.transportType(of: id),
             try hal.streamChannels(of: id, scope: .input),
             try hal.streamChannels(of: id, scope: .output))
        }
        if OutputDevice.isBluetooth(transportType: transport) && !input.isEmpty {
            throw .bluetoothInput(uid: uid)
        }
        return SubDevice(uid: uid, id: id, output: output, inputBuffers: input.count, label: label)
    }

    /// The speakers keep the rate they report and Domine never sets it
    /// (SPEC section 4a): forcing a Bluetooth speaker's nominal rate can
    /// leave it reporting one rate while its codec runs at another, which
    /// plays everything slow and low. The aggregate runs at Device A's rate
    /// (the main sub-device); if B differs, the aggregate's drift
    /// compensation converts it. This only logs.
    private func matchSpeakerRates(a: SubDevice, b: SubDevice) {
        do throws(HALError) {
            let rateA = try hal.nominalSampleRate(of: a.id)
            let rateB = try hal.nominalSampleRate(of: b.id)
            if rateA == rateB {
                Self.log.info("Speakers both run at \(rateA, privacy: .public) Hz")
            } else {
                Self.log.warning("Speakers run at different rates (A \(a.uid, privacy: .public) \(rateA, privacy: .public) Hz, B \(b.uid, privacy: .public) \(rateB, privacy: .public) Hz); the aggregate runs at A's rate and converts B")
            }
        } catch {
            Self.log.warning("Could not read the speakers' rates: \(error.description, privacy: .public)")
        }
    }

    /// Creates the tap and checks it delivers `expectedRate` (the aggregate's
    /// rate). If not, and the default output is at (or was set to) that
    /// rate, waits for the rate to settle and rebuilds the tap once, so the
    /// aggregate does not have to convert it. Returns false if a stop
    /// arrived while waiting.
    private func createTap(expectedRate: Double?, generation current: Int) async throws(EngineError) -> Bool {
        var tap = try taps.create(alsoExcluding: globalExclusions)
        resources.tap = tap
        var format = try EngineError.hal { () throws(HALError) in try hal.tapFormat(of: tap.id) }
        Self.log.info("Tap \(tap.uid, privacy: .public): \(format.mChannelsPerFrame) ch at \(format.mSampleRate) Hz")
        if let expectedRate, format.mSampleRate != expectedRate,
           resources.defaultRateRestore != nil || defaultOutputRate() == expectedRate {
            Self.log.info("Tap came up at \(format.mSampleRate, privacy: .public) Hz, not \(expectedRate, privacy: .public) Hz; rebuilding it once the default output settles")
            _ = await waitForDefaultOutputRate(expectedRate)
            guard current == generation else { return false }
            format = try EngineError.hal { () throws(HALError) in try hal.tapFormat(of: tap.id) }
            if format.mSampleRate != expectedRate {
                let old = tap
                resources.tap = nil
                try EngineError.hal { () throws(HALError) in try taps.destroy(old) }
                tap = try taps.create(alsoExcluding: globalExclusions)
                resources.tap = tap
                format = try EngineError.hal { () throws(HALError) in try hal.tapFormat(of: tap.id) }
                Self.log.info("Rebuilt tap \(tap.uid, privacy: .public): \(format.mChannelsPerFrame) ch at \(format.mSampleRate) Hz")
            }
        }
        resources.tapFormat = format
        try createAppTaps()
        return true
    }

    /// Excluded apps plus every app that has its own tap.
    private var globalExclusions: [AudioObjectID] {
        var all = excludedProcesses
        for request in appTapRequests { for p in request.processes where !all.contains(p) { all.append(p) } }
        return all
    }

    private func createAppTaps() throws(EngineError) {
        for request in appTapRequests {
            let tap = try taps.createApp(processes: request.processes)
            resources.appTaps.append((request.key, tap))
        }
    }

    /// The first present speaker is the main sub-device. A clock device
    /// that is not in the aggregate falls back to that speaker.
    private func createAggregate(_ present: [SubDevice]) throws(EngineError) {
        guard let tap = resources.tap, !present.isEmpty else { throw .kernelUnavailable }
        var clock = AggregateBuilder.clock
        if case .device(let uid) = clock, !present.contains(where: { $0.uid == uid }) { clock = .leftSpeaker }
        let description = AggregateBuilder.description(
            outputUIDs: present.map(\.uid), tapUID: tap.uid,
            appTapUIDs: resources.appTaps.map(\.tap.uid), clock: clock)
        EngineDiagnostics.logAggregateDescription(description)
        resources.aggregate = try EngineError.hal { () throws(HALError) in
            try hal.createAggregateDevice(description)
        }
    }

    /// Returns nil if a stop arrived while waiting.
    private func readLayout(a: SubDevice?, b: SubDevice?, generation current: Int) async throws(EngineError) -> AggregateLayout? {
        guard let aggregate = resources.aggregate else { return nil }
        var attempt = 1
        while true {
            let (output, input) = try EngineError.hal { () throws(HALError) in
                (try hal.streamChannels(of: aggregate, scope: .output),
                 try hal.streamChannels(of: aggregate, scope: .input))
            }
            do {
                return try AggregateLayout.compute(
                    aOutput: a?.output, bOutput: b?.output,
                    subDeviceInputBuffers: (a?.inputBuffers ?? 0) + (b?.inputBuffers ?? 0),
                    aggregateOutput: output, aggregateInput: input)
            } catch {
                if attempt >= layoutAttempts { throw error }
                Self.log.debug("Aggregate not ready (\(error.description, privacy: .public)), retrying")
            }
            attempt += 1
            try? await Task.sleep(for: layoutRetryDelay)
            if generation != current { return nil }
        }
    }

    private func startIO(layout: AggregateLayout, fadeIn: Bool) throws(EngineError) {
        guard let aggregate = resources.aggregate else { throw .kernelUnavailable }
        let rate = try EngineError.hal { () throws(HALError) in try hal.nominalSampleRate(of: aggregate) }
        guard rate.isFinite, rate > 0 else { throw .invalidSampleRate(rate) }
        guard let kernel = domine_kernel_create(rate, Self.kernelMaxFrames) else { throw .kernelUnavailable }
        resources.kernel = kernel
        domine_kernel_set_layout(
            kernel,
            UInt32(layout.inFirstBuffer),
            layout.outAChannelOffset.map { UInt32($0) } ?? DOMINE_NO_DEVICE,
            layout.outBChannelOffset.map { UInt32($0) } ?? DOMINE_NO_DEVICE)
        let format = tapStreamFormat(aggregate: aggregate, layout: layout)
        domine_kernel_set_input_format(kernel, format.channels, format.nonInterleaved ? 1 : 0)
        inputFormat = format
        pushTapLayout(layout) { domine_kernel_set_tap_layout(kernel, $0, $1, $2, $3) }
        applyTapGains()
        applyControls()
        if fadeIn { domine_kernel_start_faded_out(kernel) }

        let proc = try EngineError.hal { () throws(HALError) in
            try hal.createIOProc(on: aggregate, proc: domine_kernel_ioproc, clientData: UnsafeMutableRawPointer(kernel))
        }
        resources.ioProc = proc
        if layout.inFirstBuffer > 0 {
            // Sub-device inputs (never Bluetooth; see inspect) stay closed for our IOProc.
            let usage = Array(repeating: false, count: layout.inFirstBuffer)
                + Array(repeating: true, count: layout.tapBuffers)
            try EngineError.hal { () throws(HALError) in try hal.setInputStreamUsage(usage, for: proc) }
        }
        try EngineError.hal { () throws(HALError) in try hal.startDevice(proc) }
        resources.deviceStarted = true
    }

    /// The format the IOProc receives for the tap: the aggregate's input
    /// stream at `inFirstBuffer`, else the tap's own format. Channels count
    /// across all tap streams when non-interleaved.
    private func tapStreamFormat(aggregate: AudioObjectID, layout: AggregateLayout) -> InputFormat {
        var format = resources.tapFormat
        do {
            let streams = try hal.streamFormats(of: aggregate, scope: .input)
            if layout.inFirstBuffer < streams.count { format = streams[layout.inFirstBuffer] }
        } catch {
            Self.log.error("Could not read the aggregate's input formats: \(error.description, privacy: .public)")
        }
        guard let format else { return InputFormat(sampleRate: 0, channels: 0, nonInterleaved: false) }
        // Several tap streams (one mono stream per channel) are non-interleaved
        // as far as the kernel is concerned, whatever each stream reports.
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 || layout.tapBuffers > 1
        let isFloat32 = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        if !isFloat32 {
            Self.log.fault("Tap stream is not float32: \(EngineDiagnostics.describe(format), privacy: .public)")
        }
        // A non-interleaved stream reports one channel per buffer; the tap's
        // own format carries the real channel count.
        let channels = nonInterleaved
            ? max(format.mChannelsPerFrame, resources.tapFormat?.mChannelsPerFrame ?? 0, UInt32(layout.tapBuffers))
            : format.mChannelsPerFrame
        return InputFormat(sampleRate: format.mSampleRate, channels: channels, nonInterleaved: nonInterleaved)
    }

    /// The tap follows the system default output's rate. If that device is
    /// not one of the speakers and runs at another rate than Device A
    /// (`target`), set it to `target` when it supports it, and remember the
    /// old rate. Returns whether it set the rate.
    private func matchDefaultOutputRate(speakers: [SubDevice], target: Double) -> Bool {
        do throws(HALError) {
            let device = try hal.defaultOutputDevice()
            guard device != kAudioObjectUnknown, !speakers.contains(where: { $0.id == device }) else { return false }
            // Never set a Bluetooth device's rate (see matchSpeakerRates).
            guard !OutputDevice.isBluetooth(transportType: try hal.transportType(of: device)) else { return false }
            let uid = try hal.uid(of: device)
            let current = try hal.nominalSampleRate(of: device)
            guard current != target else { return false }
            let available = try hal.availableNominalSampleRates(of: device)
            guard available.contains(where: { $0.contains(target) }) else {
                Self.log.warning("Default output \(uid, privacy: .public) runs at \(current, privacy: .public) Hz and does not support \(target, privacy: .public) Hz; relying on tap drift compensation")
                return false
            }
            try hal.setNominalSampleRate(target, of: device)
            resources.defaultRateRestore = (uid, current)
            Self.log.info("Default output \(uid, privacy: .public) set from \(current, privacy: .public) Hz to \(target, privacy: .public) Hz to match the speakers")
            return true
        } catch {
            Self.log.warning("Could not match the default output's rate: \(error.description, privacy: .public)")
            return false
        }
    }

    /// The default output's nominal rate, or nil if there is none or the
    /// read failed.
    private func defaultOutputRate() -> Double? {
        do throws(HALError) {
            let device = try hal.defaultOutputDevice()
            guard device != kAudioObjectUnknown else { return nil }
            return try hal.nominalSampleRate(of: device)
        } catch {
            Self.log.warning("Could not read the default output's rate: \(error.description, privacy: .public)")
            return nil
        }
    }

    /// Polls the default output's nominal rate until it reads `rate`, up to
    /// `rateSettleAttempts` reads `rateSettlePoll` apart. Returns whether it
    /// did. A rate change takes effect in the HAL a few ms after the write.
    private func waitForDefaultOutputRate(_ rate: Double) async -> Bool {
        for attempt in 1...rateSettleAttempts {
            if defaultOutputRate() == rate {
                if attempt > 1 {
                    Self.log.info("Default output reports \(rate, privacy: .public) Hz after \(attempt, privacy: .public) reads")
                }
                return true
            }
            if attempt < rateSettleAttempts { try? await Task.sleep(for: rateSettlePoll) }
        }
        return false
    }

    /// Logs the rate at every stage and whether any of them converts.
    private func logSignalChain(_ present: [SubDevice]) {
        guard let rate = kernelSampleRate, let tapRate = resources.tapFormat?.mSampleRate else { return }
        let chain = SignalChain(
            sourceUID: currentDefaultOutputUID(),
            sourceRate: defaultOutputRate(),
            tapRate: tapRate,
            aggregateRate: rate,
            speakers: present.map { device in
                SignalChain.Speaker(label: device.label, uid: device.uid, rate: try? hal.nominalSampleRate(of: device.id))
            })
        signalChain = chain
        if chain.isConversionFree {
            Self.log.info("Signal chain: \(chain.summary, privacy: .public)")
        } else {
            Self.log.warning("Signal chain: \(chain.summary, privacy: .public)")
        }
    }

    private func restoreDefaultOutputRate() {
        guard let restore = resources.defaultRateRestore else { return }
        do throws(HALError) {
            let id = try hal.deviceID(forUID: restore.uid)
            guard id != kAudioObjectUnknown else { return }
            try hal.setNominalSampleRate(restore.rate, of: id)
            Self.log.info("Default output \(restore.uid, privacy: .public) restored to \(restore.rate, privacy: .public) Hz")
        } catch {
            Self.log.error("Could not restore the rate of \(restore.uid, privacy: .public): \(error.description, privacy: .public)")
        }
    }

    // MARK: - Diagnostics and format watch

    private func startDiagnostics(_ present: [SubDevice]) {
        guard let kernel = resources.kernel, let aggregate = resources.aggregate, let tap = resources.tap else { return }
        let devices = present.map { EngineDiagnostics.Device(label: $0.label, uid: $0.uid, id: $0.id) }
        EngineDiagnostics.logStartup(hal: hal, aggregate: aggregate, tap: tap, kernel: kernel, devices: devices)
        let diagnostics = EngineDiagnostics(
            hal: hal, kernel: kernel, aggregate: aggregate, devices: devices, tap: tap, interval: diagnosticsInterval)
        diagnostics.start()
        resources.diagnostics = diagnostics
    }

    /// Re-checks the tap format when the default output or a rate changes,
    /// and rebuilds if what the tap delivers changed (SPEC section 7).
    private func watchFormat() {
        resources.defaultOutputUID = currentDefaultOutputUID()
        var properties: [HALProperty] = [.defaultOutputDevice]
        if let aggregate = resources.aggregate { properties.append(.nominalSampleRate(aggregate)) }
        if let id = try? hal.defaultOutputDevice(), id != kAudioObjectUnknown {
            properties.append(.nominalSampleRate(id))
        }
        watch(properties) { [weak self] in self?.scheduleFormatCheck() }
    }

    private func watch(_ properties: [HALProperty], handler: @escaping @MainActor @Sendable () -> Void) {
        for property in properties {
            do {
                let token = try hal.addListener(property, handler: handler)
                resources.watchTokens.append(token)
            } catch {
                Self.log.error("Could not watch \(String(describing: property), privacy: .public): \(error.description, privacy: .public)")
            }
        }
    }

    private func currentDefaultOutputUID() -> String? {
        guard let id = try? hal.defaultOutputDevice(), id != kAudioObjectUnknown else { return nil }
        return try? hal.uid(of: id)
    }

    private func scheduleFormatCheck() {
        formatCheck?.cancel()
        let delay = formatCheckDelay
        formatCheck = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.checkFormat()
        }
    }

    /// Rebuilds when the default output or the tap's format changed since
    /// start. Returns whether it rebuilt.
    @discardableResult
    func checkFormat() async -> Bool {
        guard state.isRouting, let tap = resources.tap, speakers != nil || surroundRoute != nil else { return false }
        let defaultUID = currentDefaultOutputUID()
        let format: AudioStreamBasicDescription
        do {
            format = try hal.tapFormat(of: tap.id)
        } catch {
            Self.log.error("Could not re-read the tap format: \(error.description, privacy: .public)")
            return false
        }
        let old = resources.tapFormat
        let formatChanged = old.map { !Self.sameFormat($0, format) } ?? true
        guard formatChanged || defaultUID != resources.defaultOutputUID else {
            formatRebuilds = 0
            return false
        }
        // Only the default output moved (excluded apps switch it, SPEC 3b)
        // and it already runs at the tap's rate: nothing the tap delivers
        // changed, so keep playing instead of rebuilding.
        if !formatChanged, let rate = defaultOutputRate(), rate == format.mSampleRate {
            if let restore = resources.defaultRateRestore, restore.uid != defaultUID {
                restoreDefaultOutputRate()
                resources.defaultRateRestore = nil
            }
            resources.defaultOutputUID = defaultUID
            if let id = try? hal.defaultOutputDevice(), id != kAudioObjectUnknown {
                watch([.nominalSampleRate(id)]) { [weak self] in self?.scheduleFormatCheck() }
            }
            Self.log.info("Default output is now \(defaultUID ?? "none", privacy: .public) at the tap's rate; no rebuild")
            return false
        }
        guard formatRebuilds < Self.maxFormatRebuilds else {
            Self.log.error("Tap format keeps changing; not rebuilding again")
            return false
        }
        formatRebuilds += 1
        Self.log.info("Rebuilding: default output \(defaultUID ?? "none", privacy: .public), tap \(EngineDiagnostics.describe(format), privacy: .public)")
        if let route = surroundRoute {
            await rebuildSurround(uids: route, ids: resources.surroundIDs)
            return true
        }
        guard let speakers else { return false }
        if state != .running {
            // Mono fallback cannot go through start, which needs both speakers.
            await rebuild(uidA: speakers.left, uidB: speakers.right, ids: resources.speakerIDs)
            return true
        }
        halt()
        await start(left: speakers.left, right: speakers.right)
        return true
    }

    private static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mFormatFlags == b.mFormatFlags && a.mBytesPerFrame == b.mBytesPerFrame
            && a.mFormatID == b.mFormatID
    }

    // MARK: - Speakers coming and going

    /// Listens for the device list and for the IsAlive of each speaker the
    /// HAL lists, including a listed one that is not alive, so its return
    /// is noticed too.
    private func watchSpeakers() {
        guard let speakers else { return }
        var properties: [HALProperty] = [.devices]
        for uid in [speakers.left, speakers.right] {
            if let id = try? hal.deviceID(forUID: uid), id != kAudioObjectUnknown {
                properties.append(.isAlive(id))
            }
        }
        watch(properties) { [weak self] in self?.scheduleSpeakerCheck() }
    }

    /// Runs `checkSpeakers` now, or again after the check in progress.
    /// Applies a new set of excluded processes (SPEC 3b). While routing, the
    /// running tap takes the new list in place, so audio keeps playing; only
    /// if that fails is the tap rebuilt. Otherwise the set is used by the
    /// next build.
    func setExcludedProcesses(_ processes: [AudioObjectID]) async {
        guard processes != excludedProcesses else { return }
        excludedProcesses = processes
        if state.isRouting, let tap = resources.tap {
            do {
                try taps.updateExclusions(of: tap, alsoExcluding: globalExclusions)
                Self.log.info("Excluded processes changed to \(processes.count, privacy: .public); tap updated in place")
                return
            } catch {
                Self.log.error("Could not update the tap in place: \(error.description, privacy: .public); rebuilding")
            }
        }
        if state.isRouting, let route = surroundRoute {
            await rebuildSurround(uids: route, ids: resources.surroundIDs)
            return
        }
        guard state.isRouting, let speakers else { return }
        Self.log.info("Excluded processes changed to \(processes.count, privacy: .public); rebuilding the tap")
        await rebuild(uidA: speakers.left, uidB: speakers.right, ids: resources.speakerIDs)
    }

    /// Sets the apps that get their own tap. Gains apply at once without a
    /// rebuild; a changed set of apps or processes rebuilds after `appTapDebounce`.
    func setAppTaps(_ requests: [AppTapRequest]) {
        let new = Array(requests.sorted { $0.key < $1.key }.prefix(Self.maxAppTaps))
        let changed = new.map { [$0.key] + $0.processes.map(String.init) }
            != appTapRequests.map { [$0.key] + $0.processes.map(String.init) }
        appTapRequests = new
        applyTapGains()
        guard changed, state.isRouting else { return }
        appTapRebuild?.cancel()
        let delay = appTapDebounce
        appTapRebuild = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await self.rebuildForTapChange()
        }
    }

    private func rebuildForTapChange() async {
        guard state.isRouting else { return }
        Self.log.info("App taps changed to \(self.appTapRequests.count, privacy: .public); rebuilding")
        if let route = surroundRoute {
            await rebuildSurround(uids: route, ids: resources.surroundIDs)
        } else if let speakers {
            await rebuild(uidA: speakers.left, uidB: speakers.right, ids: resources.speakerIDs)
        }
    }

    /// Tells the kernel where each tap's buffers sit in the aggregate input.
    /// Only used when per-app taps exist; one tap keeps the kernel's own path.
    private func pushTapLayout(_ layout: AggregateLayout,
                               _ set: (UInt32, UnsafePointer<UInt32>, UnsafePointer<UInt32>, UnsafePointer<UInt32>) -> Void) {
        guard let aggregate = resources.aggregate, let main = resources.tap else { return }
        let all = [main] + resources.appTaps.map(\.tap)
        guard all.count > 1 else { return }
        var first: [UInt32] = [], channels: [UInt32] = [], interleaved: [UInt32] = []
        var next = layout.inFirstBuffer
        let streams = (try? hal.streamFormats(of: aggregate, scope: .input)) ?? []
        for tap in all {
            guard next < streams.count, let format = try? hal.tapFormat(of: tap.id) else { break }
            let stream = streams[next]
            let split = stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 && stream.mChannelsPerFrame == 1
            let buffers = split ? max(Int(format.mChannelsPerFrame), 1) : 1
            first.append(UInt32(next))
            channels.append(split ? UInt32(buffers) : stream.mChannelsPerFrame)
            interleaved.append(split ? 0 : 1)
            next += buffers
        }
        guard first.count == all.count, next == layout.inFirstBuffer + layout.tapBuffers else {
            Self.log.error("Per-app tap buffers do not match the aggregate input; per-app volume is off")
            return
        }
        set(UInt32(all.count), first, channels, interleaved)
    }

    /// Pushes each built per-app tap's gain. Tap 0 is the global tap (gain 1).
    private func applyTapGains() {
        let built = resources.appTaps.map(\.key)
        for (index, key) in built.enumerated() {
            let gain = Float(appTapRequests.first { $0.key == key }?.gain ?? 1)
            if let kernel = resources.kernel { domine_kernel_set_tap_gain(kernel, UInt32(index + 1), gain) }
            if let surround = resources.surround { domine_surround_set_tap_gain(surround, UInt32(index + 1), gain) }
        }
    }

    fileprivate func scheduleSpeakerCheck() {
        speakerCheckPending = true
        guard speakerCheck == nil else { return }
        speakerCheck = Task { [weak self] in await self?.runSpeakerChecks() }
    }

    /// A rebuild drops the listeners for a moment, so after one the speakers
    /// are checked once more. Capped so a flapping device cannot loop.
    private func runSpeakerChecks() async {
        var rounds = 0
        while speakerCheckPending, rounds < 8 {
            speakerCheckPending = false
            rounds += 1
            if await checkSpeakers() { speakerCheckPending = true }
        }
        speakerCheck = nil
    }

    /// The speaker's current device ID if it is in the device list and
    /// alive, else nil. Matched by UID, since IDs change on reconnect.
    fileprivate func presentID(_ uid: String) -> AudioObjectID? {
        guard let id = try? hal.deviceID(forUID: uid), id != kAudioObjectUnknown,
              (try? hal.isAlive(id)) == true else { return nil }
        return id
    }

    /// Compares the selected speakers with what the HAL reports and rebuilds
    /// when the set of present speakers, or a speaker's device ID, changed
    /// (SPEC section 7). Both gone stops the engine. Returns whether it
    /// rebuilt or stopped.
    @discardableResult
    func checkSpeakers() async -> Bool {
        if let route = surroundRoute { return await checkSurroundSpeakers(route) }
        guard state.isRouting, let speakers else { return false }
        let ids = SpeakerIDs(a: presentID(speakers.left), b: presentID(speakers.right))
        // A pair that just failed to build is not retried until something changes.
        guard ids != resources.speakerIDs, ids != refusedSpeakerIDs else { return false }
        refusedSpeakerIDs = nil
        // A device change stops the demo; the pair rebuilds on the stereo kernel (SPEC 14.4).
        startStereoDemo = false
        if ids.a == nil && ids.b == nil {
            Self.log.warning("Both speakers disconnected; stopping")
            stop()
            idleReason = .speakersDisconnected
            onRoutingEnded?()
            return true
        }
        await rebuild(uidA: speakers.left, uidB: speakers.right, ids: ids)
        return true
    }

    /// Fades out, tears everything down, and builds a fresh tap and
    /// aggregate for the speakers in `ids`, fading in. If both speakers were
    /// asked for and that fails, it falls back to the one that was playing.
    private func rebuild(uidA: String, uidB: String, ids: SpeakerIDs) async {
        let previous = resources.speakerIDs
        await fadeOut()
        guard state.isRouting, resources.speakerIDs == previous else { return }
        Self.log.info("Rebuilding for speakers A \(ids.a.map { "\($0)" } ?? "missing", privacy: .public), B \(ids.b.map { "\($0)" } ?? "missing", privacy: .public)")
        generation &+= 1
        teardown()
        layout = nil
        guard var error = await build(uidA: uidA, uidB: uidB, ids: ids, fadeIn: true) else { return }
        if ids.a != nil, ids.b != nil, previous.a == nil || previous.b == nil {
            var single = previous
            if let id = single.a { single.a = presentID(uidA) == id ? id : nil }
            if let id = single.b { single.b = presentID(uidB) == id ? id : nil }
            if single.a != nil || single.b != nil {
                Self.log.warning("Stereo rebuild failed (\(error.description, privacy: .public)); staying in mono fallback")
                generation &+= 1
                guard let again = await build(uidA: uidA, uidB: uidB, ids: single, fadeIn: true) else {
                    refusedSpeakerIDs = ids
                    return
                }
                error = again
            }
        }
        stop()
        state = .error(error.description)
        onRoutingEnded?()
    }

    /// Ramps the kernel to silence over its 50 ms fade and waits it out.
    private func fadeOut() async {
        guard resources.kernel != nil || resources.surround != nil else { return }
        fadingOut = true
        defer { fadingOut = false }
        if let surround = resources.surround {
            domine_surround_set_muted(surround, 1)
        } else if let kernel = resources.kernel {
            domine_kernel_set_muted(kernel, 1)
        }
        await fadeWait(Self.rebuildFadeWait)
    }

    // MARK: - Teardown

    /// Releases everything in `resources`, in reverse creation order. Errors
    /// are logged, not thrown, so one failure never strands the rest.
    private func teardown() {
        resources.diagnostics?.stop()
        resources.watchTokens.forEach { $0.cancel() }
        var ioProcGone = true
        var aggregateGone = true
        if let proc = resources.ioProc {
            if resources.deviceStarted {
                release("stop device") { () throws(HALError) in try hal.stopDevice(proc) }
            }
            ioProcGone = release("destroy IOProc") { () throws(HALError) in try hal.destroyIOProc(proc) }
        }
        if let aggregate = resources.aggregate {
            aggregateGone = release("destroy aggregate") { () throws(HALError) in
                try hal.destroyAggregateDevice(aggregate)
            }
        }
        for (_, tap) in resources.appTaps {
            release("destroy app tap") { () throws(HALError) in try taps.destroy(tap) }
        }
        if let tap = resources.tap {
            release("destroy tap") { () throws(HALError) in try taps.destroy(tap) }
        }
        if let kernel = resources.kernel {
            if ioProcGone || aggregateGone {
                domine_kernel_destroy(kernel)
            } else {
                // The IOProc may still run and read the kernel; leaking is the safe choice.
                Self.log.fault("IOProc and aggregate survived teardown; leaking the kernel")
            }
        }
        if let surround = resources.surround {
            if ioProcGone || aggregateGone {
                domine_surround_destroy(surround)
            } else {
                Self.log.fault("IOProc and aggregate survived teardown; leaking the surround kernel")
            }
        }
        restoreDefaultOutputRate()
        resources = Resources()
    }

    @discardableResult
    private func release(_ what: String, _ body: () throws(HALError) -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            Self.log.error("Could not \(what, privacy: .public): \(error.description, privacy: .public)")
            return false
        }
    }

    private func isEmpty(_ r: Resources) -> Bool {
        r.tap == nil && r.aggregate == nil && r.kernel == nil && r.surround == nil && r.ioProc == nil
    }

    // MARK: - Meters and diagnostics

    /// Linear peaks the kernel last wrote to position A (Front Left device)
    /// and position B (Front Right device). Both 0 when not running. On the
    /// surround kernel: speakers 0 and 1 (A and B during the stereo demo).
    func peaks() -> (Float, Float) {
        if state.isRouting, let surround = resources.surround {
            let count = resources.surroundUIDs.count
            return (count > 0 ? domine_surround_peak(surround, 0) : 0,
                    count > 1 ? domine_surround_peak(surround, 1) : 0)
        }
        guard state.isRouting, let kernel = resources.kernel else { return (0, 0) }
        return (domine_kernel_peak(kernel, 0), domine_kernel_peak(kernel, 1))
    }

    /// The orbit phase in degrees as it is heard: the kernel's phase moved
    /// back by the time its output takes to reach the ears (each speaker's
    /// delay plus its reported latency, the longest of them). nil unless a
    /// surround kernel is routing.
    func heardOrbitPhase() -> Double? {
        guard state.isRouting, let surround = resources.surround, surroundRoute != nil else { return nil }
        let phase = Double(domine_surround_orbit_phase(surround))
        guard orbitRate != 0, !demoRequested, !stereoDemo else { return phase }
        return phase - Double(orbitRate) * orbitOutputDelaySeconds()
    }

    @ObservationIgnored private var orbitDelayCache: (key: [String], delaysMs: [Float], seconds: Double)?

    /// Read once per route and delay set; latency reads go to the HAL.
    private func orbitOutputDelaySeconds() -> Double {
        let uids = resources.surroundUIDs
        let delays = pushedSurround?.delaysMs ?? []
        if let cache = orbitDelayCache, cache.key == uids, cache.delaysMs == delays { return cache.seconds }
        var longest = 0.0
        for (index, uid) in uids.enumerated() where index < resources.surroundPresent.count && resources.surroundPresent[index] {
            let delay = index < delays.count ? Double(delays[index]) : 0
            longest = max(longest, delay + (reportedLatencyMs(uid: uid) ?? 0))
        }
        let seconds = longest / 1000
        orbitDelayCache = (uids, delays, seconds)
        return seconds
    }

    /// Total output latency the device reports, in ms at its nominal rate.
    /// nil when the device is absent or a read fails (the failure is logged).
    func reportedLatencyMs(uid: String) -> Double? {
        do throws(HALError) {
            let id = try hal.deviceID(forUID: uid)
            guard id != kAudioObjectUnknown else { return nil }
            let latency = try hal.outputLatency(of: id)
            return latency.milliseconds(sampleRate: try hal.nominalSampleRate(of: id))
        } catch {
            Self.log.error("Could not read latency of \(uid, privacy: .public): \(error.description, privacy: .public)")
            return nil
        }
    }

    // MARK: - Controls

    private func applyControls() {
        if let surround = resources.surround { return applySurroundControls(surround) }
        guard let kernel = resources.kernel else { return }
        domine_kernel_set_mode(kernel, monoPerSpeaker ? 1 : 0, swapSides ? 1 : 0, kernelMonoFallback ? 1 : 0)
        domine_kernel_set_test_tone(kernel, testTone.rawValue)
        domine_kernel_set_click_test(kernel, calibrationChirps ? 2 : (clickTest ? 1 : 0))
        domine_kernel_set_gains(kernel, leftGain, rightGain)
        domine_kernel_set_delay_ms(kernel, delayMs)
        domine_kernel_set_muted(kernel, muted || fadingOut ? 1 : 0)
        pushedEQ = []
        for (position, fx) in [(Int32(0), effectsA), (Int32(1), effectsB)] {
            var eq = fx.eqParams
            var bass = fx.bassParams
            var comp = fx.compressorParams
            domine_kernel_set_eq(kernel, position, &eq)
            domine_kernel_set_bass(kernel, position, &bass)
            domine_kernel_set_compressor(kernel, position, &comp)
            pushedEQ.append(eq)
        }
    }
}

// MARK: - Surround routing (SPEC 13)

extension Engine {
    /// Routes the surround set in list order. Speakers that are not
    /// connected are left out of this build and rejoin when they return;
    /// at least one must be present. Stereo routing is `start(left:right:)`.
    func start(surround speakers: [SurroundSpeaker]) async {
        switch state {
        case .idle, .error: break
        case .starting, .running, .degraded, .stopping: return
        }
        idleReason = nil
        let uids = speakers.map(\.uid)
        guard !uids.isEmpty else { return refuse(.noSurroundSpeakers) }
        guard Set(uids).count == uids.count, uids.count <= SurroundSpeaker.maxCount else {
            return refuse(.sameSpeaker)
        }
        var ids: [AudioObjectID?] = []
        for uid in uids {
            do {
                let id = try hal.deviceID(forUID: uid)
                ids.append(id == kAudioObjectUnknown ? nil : id)
            } catch {
                state = .error(EngineError.hal(error).description)
                return
            }
        }
        guard ids.contains(where: { $0 != nil }) else { return refuse(.surroundMissing) }
        state = .starting
        generation &+= 1
        surroundSpeakers = speakers
        surroundRoute = uids
        if let error = await buildSurround(uids: uids, ids: ids, fadeIn: false) {
            surroundRoute = nil
            state = .error(error.description)
        }
    }

    /// Builds the tap, an aggregate of the present speakers in list order
    /// (the first present one is the clock), the surround kernel with the
    /// full layout (absent speakers get DOMINE_NO_DEVICE) and its IOProc.
    /// Returns the error, or nil on success or a quiet cancel.
    private func buildSurround(uids: [String], ids: [AudioObjectID?], fadeIn: Bool) async -> EngineError? {
        let current = generation
        // A fresh kernel has no demo; a rebuild ends one (SPEC 14.4).
        endDemoState()
        do throws(EngineError) {
            var devices: [SubDevice?] = []
            for (index, uid) in uids.enumerated() {
                if let id = ids[index] {
                    devices.append(try inspect(uid: uid, id: id, label: "S\(index + 1)"))
                } else {
                    devices.append(nil)
                }
            }
            let present = devices.compactMap { $0 }
            guard let main = present.first else { throw .kernelUnavailable }
            let targetRate = try? hal.nominalSampleRate(of: main.id)
            if let targetRate, matchDefaultOutputRate(speakers: present, target: targetRate) {
                if !(await waitForDefaultOutputRate(targetRate)) {
                    Self.log.warning("Default output did not report \(targetRate, privacy: .public) Hz within the wait; creating the tap anyway")
                }
                guard current == generation else { return nil }
            }
            guard try await createTap(expectedRate: targetRate, generation: current) else { return nil }
            try createAggregate(present)
            guard let layout = try await readSurroundLayout(devices, generation: current), current == generation else { return nil }
            try startSurroundIO(layout: layout, uids: uids, fadeIn: fadeIn)
            self.layout = layout
            resources.surroundIDs = ids
            let missing = uids.indices.filter { ids[$0] == nil }.map { uids[$0] }
            state = missing.isEmpty ? .running : .degraded(.quadFallback(missing: missing))
            Self.log.info("Surround: \(present.map { "\($0.label) \($0.uid)" }.joined(separator: ", "), privacy: .public), layout \(String(describing: layout), privacy: .public)")
            watchFormat()
            watchSurroundSpeakers(uids)
            return nil
        } catch {
            guard current == generation else { return nil }
            teardown()
            layout = nil
            Self.log.error("Surround start failed: \(error.description, privacy: .public)")
            return error
        }
    }

    private func readSurroundLayout(_ devices: [SubDevice?], generation current: Int) async throws(EngineError) -> AggregateLayout? {
        guard let aggregate = resources.aggregate else { return nil }
        var attempt = 1
        while true {
            let (output, input) = try EngineError.hal { () throws(HALError) in
                (try hal.streamChannels(of: aggregate, scope: .output),
                 try hal.streamChannels(of: aggregate, scope: .input))
            }
            do {
                return try AggregateLayout.compute(
                    outputs: devices.map { $0?.output },
                    subDeviceInputBuffers: devices.reduce(0) { $0 + ($1?.inputBuffers ?? 0) },
                    aggregateOutput: output, aggregateInput: input)
            } catch {
                if attempt >= layoutAttempts { throw error }
            }
            attempt += 1
            try? await Task.sleep(for: layoutRetryDelay)
            if generation != current { return nil }
        }
    }

    /// Creates the surround kernel for `uids` (one per entry of
    /// `layout.outOffsets`, in order), stores the layout, and starts the IOProc.
    fileprivate func startSurroundIO(layout: AggregateLayout, uids: [String], fadeIn: Bool) throws(EngineError) {
        guard let aggregate = resources.aggregate, uids.count == layout.outOffsets.count, !uids.isEmpty else {
            throw .kernelUnavailable
        }
        let rate = try EngineError.hal { () throws(HALError) in try hal.nominalSampleRate(of: aggregate) }
        guard rate.isFinite, rate > 0 else { throw .invalidSampleRate(rate) }
        guard let surround = domine_surround_create(rate, Self.kernelMaxFrames) else { throw .kernelUnavailable }
        resources.surround = surround
        resources.surroundUIDs = uids
        resources.surroundPresent = layout.outOffsets.map { $0 != nil }
        resources.surroundRate = rate
        let offsets: [UInt32] = layout.outOffsets.map { $0.map { UInt32($0) } ?? DOMINE_NO_DEVICE }
        offsets.withUnsafeBufferPointer {
            domine_surround_set_layout(surround, UInt32(layout.inFirstBuffer), UInt32($0.count), $0.baseAddress!)
        }
        let format = tapStreamFormat(aggregate: aggregate, layout: layout)
        domine_surround_set_input_format(surround, format.channels, format.nonInterleaved ? 1 : 0)
        inputFormat = format
        pushTapLayout(layout) { domine_surround_set_tap_layout(surround, $0, $1, $2, $3) }
        applyTapGains()
        if fadeIn { domine_surround_start_faded_out(surround) }
        applySurroundControls(surround)

        let proc = try EngineError.hal { () throws(HALError) in
            try hal.createIOProc(on: aggregate, proc: domine_surround_ioproc, clientData: UnsafeMutableRawPointer(surround))
        }
        resources.ioProc = proc
        if layout.inFirstBuffer > 0 {
            let usage = Array(repeating: false, count: layout.inFirstBuffer)
                + Array(repeating: true, count: layout.tapBuffers)
            try EngineError.hal { () throws(HALError) in try hal.setInputStreamUsage(usage, for: proc) }
        }
        try EngineError.hal { () throws(HALError) in try hal.startDevice(proc) }
        resources.deviceStarted = true
    }

    /// One kernel speaker's controls before distance compensation.
    private struct SurroundEntry {
        let azimuth: Float
        let distance: Float
        let gain: Float
        let offsetMs: Float
        let effects: PairSettings.SideEffects
    }

    /// The stereo demo plays A at -30 and B at +30 (swapped: the other way
    /// round) with the pair's gains, delay and effects; a surround route
    /// uses the set's positions and per-speaker values.
    private func surroundEntries() -> [SurroundEntry] {
        let uids = resources.surroundUIDs
        if stereoDemo, uids.count == 2 {
            let left: Float = swapSides ? 30 : -30
            return [
                SurroundEntry(azimuth: left, distance: 2, gain: leftGain, offsetMs: max(-delayMs, 0), effects: effectsA),
                SurroundEntry(azimuth: -left, distance: 2, gain: rightGain, offsetMs: max(delayMs, 0), effects: effectsB),
            ]
        }
        return uids.map { uid in
            let speaker = surroundSpeakers.first { $0.uid == uid }
            return SurroundEntry(
                azimuth: speaker?.azimuth ?? 0, distance: speaker?.distance ?? 2,
                gain: surroundGains[uid] ?? 1, offsetMs: surroundDelaysMs[uid] ?? 0,
                effects: surroundEffects[uid] ?? PairSettings.SideEffects())
        }
    }

    /// Pushes positions, distance compensation combined with trims and
    /// offsets (SPEC 13.4), effects, field controls, test tone, click test,
    /// and mute. While the demo plays, rotation and orbit are 0 (SPEC 14.3).
    fileprivate func applySurroundControls(_ surround: OpaquePointer) {
        let entries = surroundEntries()
        let count = entries.count
        guard count > 0 else { return }
        let present = resources.surroundPresent.count == count ? resources.surroundPresent : Array(repeating: true, count: count)
        let presentIndexes = (0..<count).filter { present[$0] }

        // Distance compensation over the present speakers only.
        var distanceDelay = [Float](repeating: 0, count: count)
        var distanceGain = [Float](repeating: 1, count: count)
        if !presentIndexes.isEmpty {
            let distances = presentIndexes.map { entries[$0].distance }
            var delays = [Float](repeating: 0, count: distances.count)
            var gains = [Float](repeating: 1, count: distances.count)
            domine_surround_distance_comp(UInt32(distances.count), distances, &delays, &gains)
            for (k, index) in presentIndexes.enumerated() {
                distanceDelay[index] = delays[k]
                distanceGain[index] = gains[k]
            }
        }
        // Measured offsets already include acoustic travel (SPEC 13.4).
        let measured = surroundTimingMeasured && !stereoDemo
        var totals = (0..<count).map { (measured ? 0 : distanceDelay[$0]) + max(entries[$0].offsetMs, 0) }
        let earliest = presentIndexes.map { totals[$0] }.min() ?? 0
        let maxDelay = PairSettings.delayLimitMs
        totals = totals.map { min(max($0 - earliest, 0), maxDelay) }
        let gains = (0..<count).map { min(max(entries[$0].gain, 0), 1) * distanceGain[$0] }

        let azimuths = entries.map(\.azimuth)
        domine_surround_set_speakers(surround, UInt32(count), azimuths)
        for index in 0..<count {
            let speaker = UInt32(index)
            domine_surround_set_gain(surround, speaker, gains[index])
            domine_surround_set_delay_ms(surround, speaker, totals[index])
            let fx = entries[index].effects
            var eq = fx.eqParams
            var bass = fx.bassParams
            var comp = fx.compressorParams
            domine_surround_set_eq(surround, speaker, &eq)
            domine_surround_set_bass(surround, speaker, &bass)
            domine_surround_set_compressor(surround, speaker, &comp)
        }
        let width: Float = stereoDemo ? 30 : surroundWidth
        let demoField = demoRequested || stereoDemo
        let fieldRotation: Float = demoField ? 0 : rotation
        let orbit: Float = demoField ? 0 : orbitRate
        domine_surround_set_width(surround, width)
        domine_surround_set_rotation(surround, fieldRotation)
        domine_surround_set_orbit_rate(surround, orbit)
        // Stereo routing (the stereo demo) stays plain L and R.
        domine_surround_set_surround_level(surround, stereoDemo ? 0 : surroundLevel)
        domine_surround_set_mono(surround, surroundMono && !stereoDemo ? 1 : 0)
        var spatial = DomineSpatialParams(amount: spatialAmount, roomMs: spatialRoomMs, highCutHz: 5000)
        domine_surround_set_spatial(surround, &spatial)
        domine_surround_set_test_tone(surround, surroundToneIndex())
        domine_surround_set_click_test(surround, clickTest ? 1 : 0)
        let pair = surroundCalibrationPair
        domine_surround_set_calibration_pair(surround, Int32(pair?.rising ?? -1), Int32(pair?.falling ?? -1))
        domine_surround_set_muted(surround, muted || fadingOut ? 1 : 0)
        pushedSurround = PushedSurround(azimuths: azimuths, gains: gains, delaysMs: totals,
                                        width: width, rotation: fieldRotation, orbitRate: orbit)
    }

    /// Kernel index for the test tone: the surround tone's UID, or in the
    /// stereo demo the stereo tone's position (A is 0, B is 1); -1 is off.
    private func surroundToneIndex() -> Int32 {
        if stereoDemo {
            switch testTone {
            case .off: return -1
            case .left: return 0
            case .right: return 1
            }
        }
        guard let uid = surroundTestTone, let index = resources.surroundUIDs.firstIndex(of: uid) else { return -1 }
        return Int32(index)
    }

    /// Returns the orbit phase to 0 at the next process call (the "Reset"
    /// next to Orbit speed, SPEC 13.3).
    func resetOrbit() {
        if let surround = resources.surround { domine_surround_reset_orbit(surround) }
    }

    /// Linear peak per routed surround speaker in list order; 0 for one left
    /// out of this build. Empty when not routing surround.
    func surroundPeaks() -> [Float] {
        guard state.isRouting, let surround = resources.surround, surroundRoute != nil else { return [] }
        return resources.surroundPresent.indices.map { index in
            resources.surroundPresent[index] ? domine_surround_peak(surround, UInt32(index)) : 0
        }
    }

    private func watchSurroundSpeakers(_ uids: [String]) {
        var properties: [HALProperty] = [.devices]
        for uid in uids {
            if let id = try? hal.deviceID(forUID: uid), id != kAudioObjectUnknown { properties.append(.isAlive(id)) }
        }
        watch(properties) { [weak self] in self?.scheduleSpeakerCheck() }
    }

    /// Rebuilds with the present speakers when the set or an ID changed
    /// (VBAP re-pans in the kernel); all gone stops the engine (SPEC 13.5).
    fileprivate func checkSurroundSpeakers(_ uids: [String]) async -> Bool {
        guard state.isRouting else { return false }
        let ids = uids.map { presentID($0) }
        guard ids != resources.surroundIDs else { return false }
        if ids.allSatisfy({ $0 == nil }) {
            Self.log.warning("All surround speakers disconnected; stopping")
            stop()
            idleReason = .speakersDisconnected
            onRoutingEnded?()
            return true
        }
        await rebuildSurround(uids: uids, ids: ids)
        return true
    }

    fileprivate func rebuildSurround(uids: [String], ids: [AudioObjectID?]) async {
        let previous = resources.surroundIDs
        await fadeOut()
        guard state.isRouting, resources.surroundIDs == previous else { return }
        Self.log.info("Rebuilding surround for \(ids.map { $0.map { "\($0)" } ?? "missing" }.joined(separator: ", "), privacy: .public)")
        generation &+= 1
        teardown()
        layout = nil
        guard let error = await buildSurround(uids: uids, ids: ids, fadeIn: true) else { return }
        stop()
        state = .error(error.description)
        onRoutingEnded?()
    }
}

// MARK: - Demo (SPEC 14)

extension Engine {
    /// Starts (or restarts) or stops the demo. Surround routing switches it
    /// in the kernel. Stereo routing rebuilds once onto the surround kernel
    /// with the pair at -30 and +30 and back to the stereo kernel when the
    /// demo ends or is stopped (SPEC 14.4). Needs routing with at least two
    /// speakers present.
    func setDemo(_ on: Bool) async {
        guard state.isRouting else { return }
        if surroundRoute != nil, let surround = resources.surround {
            guard !on || resources.surroundPresent.filter({ $0 }).count >= 2 else { return }
            if on {
                beginDemoState()
                domine_surround_reset_orbit(surround)
                applySurroundControls(surround)
                domine_surround_set_demo(surround, 1)
            } else {
                domine_surround_set_demo(surround, 0)
                endDemoState()
                applySurroundControls(surround)
            }
            return
        }
        if stereoDemo, let surround = resources.surround {
            if on {
                beginDemoState()
                domine_surround_set_demo(surround, 1)
            } else {
                await endStereoDemo()
            }
            return
        }
        guard on, let speakers, resources.kernel != nil,
              resources.speakerIDs.a != nil, resources.speakerIDs.b != nil else { return }
        beginDemoState()
        startStereoDemo = true
        await rebuild(uidA: speakers.left, uidB: speakers.right, ids: resources.speakerIDs)
        startStereoDemo = false
        if !stereoDemo { endDemoState() }
    }

    /// What the demo is doing, for the UI (any time; all zero without a
    /// surround kernel). `section` is a DOMINE_DEMO_SECTION_*.
    func demoStatus() -> (playing: Bool, seconds: Float, azimuth: Float, section: Int32) {
        guard let surround = resources.surround else { return (false, 0, 0, 0) }
        var seconds: Float = 0
        var azimuth: Float = 0
        var section: Int32 = 0
        let playing = domine_surround_demo_status(surround, &seconds, &azimuth, &section) != 0
        return (playing, seconds, azimuth, section)
    }

    /// Marks the demo as asked for and starts watching for its end.
    private func beginDemoState() {
        demoRequested = true
        watchDemo()
    }

    /// Marks the demo as over. The watch ends at its next poll.
    fileprivate func endDemoState() {
        demoWatch?.cancel()
        demoWatch = nil
        if demoRequested { demoRequested = false }
    }

    /// Polls the kernel until the demo finishes, then restores the field
    /// controls (surround) or returns to the stereo kernel (stereo demo).
    private func watchDemo() {
        demoWatch?.cancel()
        let interval = demoPollInterval
        let grace = demoStartGrace
        demoWatch = Task { [weak self] in
            var waited: Duration = .zero
            var seenPlaying = false
            while true {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.demoRequested else { return }
                waited += interval
                if self.demoStatus().playing {
                    seenPlaying = true
                } else if seenPlaying || waited >= grace {
                    await self.demoFinished()
                    return
                }
            }
        }
    }

    /// Called from the watch once the kernel reports the demo over.
    private func demoFinished() async {
        // This runs inside the watch task: drop it without cancelling, so the
        // rebuild's fade waits still sleep.
        demoWatch = nil
        if stereoDemo {
            await endStereoDemo()
        } else {
            demoRequested = false
            if let surround = resources.surround { applySurroundControls(surround) }
        }
    }

    /// Back from the stereo demo to the stereo kernel, with fades. The pair
    /// keeps its demo positions while it fades out; `build` clears
    /// `stereoDemo` when it creates the stereo kernel.
    private func endStereoDemo() async {
        demoWatch?.cancel()
        demoWatch = nil
        demoRequested = false
        startStereoDemo = false
        if state.isRouting, let speakers {
            await rebuild(uidA: speakers.left, uidB: speakers.right, ids: resources.speakerIDs)
        }
        if resources.surround == nil { stereoDemo = false }
    }
}
