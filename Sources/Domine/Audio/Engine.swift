import CoreAudio
import DomineDSP
import Observation
import os

/// Owns the tap, the private aggregate, the IOProc, and the render kernel
/// (SPEC sections 3.2 and 7).
///
/// Start: validate devices, set 48 kHz where possible, create the tap, create
/// the aggregate, read its stream layout, create the kernel and store the
/// layout in it, create the IOProc, start the device. Any failure unwinds
/// what was created, in reverse, and ends in `.error`.
/// Stop: stop the device, destroy the IOProc, the aggregate, the tap, and
/// last the kernel, once no IOProc can call into it.
@MainActor
@Observable
final class Engine {
    static let preferredSampleRate: Double = 48_000
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
    var leftGain: Float = 1 { didSet { applyControls() } }
    var rightGain: Float = 1 { didSet { applyControls() } }
    /// Positive delays the right speaker, negative the left (SPEC section 4).
    var delayMs: Float = 0 { didSet { applyControls() } }
    /// Fades the output out (or back in) over 50 ms in the kernel.
    var muted = false { didSet { applyControls() } }
    let monoPerSpeaker = true

    var isKernelAllocated: Bool { resources.kernel != nil }

    private struct Resources {
        var tap: ProcessTap?
        var aggregate: AudioObjectID?
        var kernel: OpaquePointer?
        var ioProc: IOProcHandle?
        var deviceStarted = false
        /// The default output's rate before Domine matched it (restored on stop).
        var defaultRateRestore: (uid: String, rate: Double)?
        var diagnostics: EngineDiagnostics?
        var watchTokens: [HALListenerToken] = []
        /// What the tap delivered at start, to notice a change while running.
        var tapFormat: AudioStreamBasicDescription?
        var defaultOutputUID: String?
    }

    /// Kernel input format chosen at start (for tests and the log).
    struct InputFormat: Equatable, Sendable {
        let sampleRate: Double
        let channels: UInt32
        let nonInterleaved: Bool
    }

    /// The tap stream format the kernel was told about at the last start.
    private(set) var inputFormat: InputFormat?
    /// The running diagnostics, for tests.
    var diagnostics: EngineDiagnostics? { resources.diagnostics }

    private struct SubDevice {
        let uid: String
        let id: AudioObjectID
        let output: [Int]
        let inputBuffers: Int
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
    @ObservationIgnored private var speakers: (left: String, right: String)?
    @ObservationIgnored private var formatCheck: Task<Void, Never>?
    /// Rebuilds in a row caused by format changes; capped so a flapping
    /// device cannot rebuild forever.
    @ObservationIgnored private var formatRebuilds = 0
    static let maxFormatRebuilds = 3

    /// The aggregate may publish its streams a moment after creation, so the
    /// layout read is retried up to `layoutAttempts` times.
    init(hal: any AudioHAL, layoutAttempts: Int = 10, layoutRetryDelay: Duration = .milliseconds(50),
         diagnosticsInterval: Duration = .seconds(2), formatCheckDelay: Duration = .milliseconds(300)) {
        self.hal = hal
        self.taps = TapController(hal: hal)
        self.layoutAttempts = max(1, layoutAttempts)
        self.layoutRetryDelay = layoutRetryDelay
        self.diagnosticsInterval = diagnosticsInterval
        self.formatCheckDelay = formatCheckDelay
    }

    // MARK: - Start and stop

    func start(left uidA: String?, right uidB: String?) async {
        switch state {
        case .idle, .error: break
        case .starting, .running, .stopping: return
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
        let current = generation
        do throws(EngineError) {
            let a = try inspect(uid: uidA, id: idA)
            let b = try inspect(uid: uidB, id: idB)
            setPreferredSampleRate(a)
            setPreferredSampleRate(b)
            matchDefaultOutputRate(a: a, b: b)
            try createTapAndAggregate(a: a, b: b)
            guard let layout = try await readLayout(a: a, b: b, generation: current),
                  current == generation else { return }
            try startIO(layout: layout)
            self.layout = layout
            speakers = (uidA, uidB)
            state = .running
            Self.log.info("Running: A \(a.uid, privacy: .public), B \(b.uid, privacy: .public), layout \(String(describing: layout), privacy: .public)")
            startDiagnostics(a: a, b: b)
            watchFormat()
        } catch {
            guard current == generation else { return }
            teardown()
            state = .error(error.description)
            Self.log.error("Start failed: \(error.description, privacy: .public)")
        }
    }

    func stop() {
        formatCheck?.cancel()
        formatCheck = nil
        formatRebuilds = 0
        speakers = nil
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

    private func refuse(_ reason: IdleReason) {
        idleReason = reason
        state = .idle
    }

    // MARK: - Start steps

    /// Reads a sub-device's streams. Refuses a Bluetooth device with input
    /// streams, because the aggregate would open that input (SPEC section 9).
    private func inspect(uid: String, id: AudioObjectID) throws(EngineError) -> SubDevice {
        let (transport, input, output) = try EngineError.hal { () throws(HALError) in
            (try hal.transportType(of: id),
             try hal.streamChannels(of: id, scope: .input),
             try hal.streamChannels(of: id, scope: .output))
        }
        if OutputDevice.isBluetooth(transportType: transport) && !input.isEmpty {
            throw .bluetoothInput(uid: uid)
        }
        return SubDevice(uid: uid, id: id, output: output, inputBuffers: input.count)
    }

    /// Best effort: a device that refuses 48 kHz is left to the aggregate's
    /// rate conversion (SPEC section 4a).
    private func setPreferredSampleRate(_ device: SubDevice) {
        do {
            if try hal.nominalSampleRate(of: device.id) != Self.preferredSampleRate {
                try hal.setNominalSampleRate(Self.preferredSampleRate, of: device.id)
            }
        } catch {
            Self.log.warning("Could not set 48 kHz on \(device.uid, privacy: .public): \(error.description, privacy: .public)")
        }
    }

    private func createTapAndAggregate(a: SubDevice, b: SubDevice) throws(EngineError) {
        let tap = try taps.create()
        resources.tap = tap
        let format = try EngineError.hal { () throws(HALError) in try hal.tapFormat(of: tap.id) }
        Self.log.info("Tap \(tap.uid, privacy: .public): \(format.mChannelsPerFrame) ch at \(format.mSampleRate) Hz")
        resources.tapFormat = format
        let description = AggregateBuilder.description(uidA: a.uid, uidB: b.uid, tapUID: tap.uid)
        EngineDiagnostics.logAggregateDescription(description)
        resources.aggregate = try EngineError.hal { () throws(HALError) in
            try hal.createAggregateDevice(description)
        }
    }

    /// Returns nil if a stop arrived while waiting.
    private func readLayout(a: SubDevice, b: SubDevice, generation current: Int) async throws(EngineError) -> AggregateLayout? {
        guard let aggregate = resources.aggregate else { return nil }
        var attempt = 1
        while true {
            let (output, input) = try EngineError.hal { () throws(HALError) in
                (try hal.streamChannels(of: aggregate, scope: .output),
                 try hal.streamChannels(of: aggregate, scope: .input))
            }
            do {
                return try AggregateLayout.compute(
                    aOutput: a.output, bOutput: b.output,
                    subDeviceInputBuffers: a.inputBuffers + b.inputBuffers,
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

    private func startIO(layout: AggregateLayout) throws(EngineError) {
        guard let aggregate = resources.aggregate else { throw .kernelUnavailable }
        let rate = try EngineError.hal { () throws(HALError) in try hal.nominalSampleRate(of: aggregate) }
        guard rate.isFinite, rate > 0 else { throw .invalidSampleRate(rate) }
        guard let kernel = domine_kernel_create(rate, Self.kernelMaxFrames) else { throw .kernelUnavailable }
        resources.kernel = kernel
        domine_kernel_set_layout(
            kernel,
            UInt32(layout.inFirstBuffer),
            UInt32(layout.outAChannelOffset),
            layout.outBChannelOffset.map { UInt32($0) } ?? DOMINE_NO_DEVICE)
        let format = tapStreamFormat(aggregate: aggregate, layout: layout)
        domine_kernel_set_input_format(kernel, format.channels, format.nonInterleaved ? 1 : 0)
        inputFormat = format
        if format.sampleRate != rate {
            Self.log.warning("Tap delivers \(format.sampleRate, privacy: .public) Hz but the aggregate runs at \(rate, privacy: .public) Hz; relying on tap drift compensation")
        }
        applyControls()

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
    /// not one of the speakers and runs at another rate than Device A, set it
    /// to Device A's rate when it supports it, and remember the old rate.
    private func matchDefaultOutputRate(a: SubDevice, b: SubDevice) {
        do throws(HALError) {
            let target = try hal.nominalSampleRate(of: a.id)
            let device = try hal.defaultOutputDevice()
            guard device != kAudioObjectUnknown, device != a.id, device != b.id else { return }
            let uid = try hal.uid(of: device)
            let current = try hal.nominalSampleRate(of: device)
            guard current != target else { return }
            let available = try hal.availableNominalSampleRates(of: device)
            guard available.contains(where: { $0.contains(target) }) else {
                Self.log.warning("Default output \(uid, privacy: .public) runs at \(current, privacy: .public) Hz and does not support \(target, privacy: .public) Hz; relying on tap drift compensation")
                return
            }
            try hal.setNominalSampleRate(target, of: device)
            resources.defaultRateRestore = (uid, current)
            Self.log.info("Default output \(uid, privacy: .public) set from \(current, privacy: .public) Hz to \(target, privacy: .public) Hz to match the speakers")
        } catch {
            Self.log.warning("Could not match the default output's rate: \(error.description, privacy: .public)")
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

    private func startDiagnostics(a: SubDevice, b: SubDevice) {
        guard let kernel = resources.kernel, let aggregate = resources.aggregate, let tap = resources.tap else { return }
        let devices = [
            EngineDiagnostics.Device(label: "A", uid: a.uid, id: a.id),
            EngineDiagnostics.Device(label: "B", uid: b.uid, id: b.id),
        ]
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
        for property in properties {
            do {
                let token = try hal.addListener(property) { [weak self] in self?.scheduleFormatCheck() }
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
        guard state == .running, let tap = resources.tap, let speakers else { return false }
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
        guard formatRebuilds < Self.maxFormatRebuilds else {
            Self.log.error("Tap format keeps changing; not rebuilding again")
            return false
        }
        formatRebuilds += 1
        Self.log.info("Rebuilding: default output \(defaultUID ?? "none", privacy: .public), tap \(EngineDiagnostics.describe(format), privacy: .public)")
        halt()
        await start(left: speakers.left, right: speakers.right)
        return true
    }

    private static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mFormatFlags == b.mFormatFlags && a.mBytesPerFrame == b.mBytesPerFrame
            && a.mFormatID == b.mFormatID
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
        r.tap == nil && r.aggregate == nil && r.kernel == nil && r.ioProc == nil
    }

    // MARK: - Meters and diagnostics

    /// Linear peaks the kernel last wrote to position A (Front Left device)
    /// and position B (Front Right device). Both 0 when not running.
    func peaks() -> (Float, Float) {
        guard state == .running, let kernel = resources.kernel else { return (0, 0) }
        return (domine_kernel_peak(kernel, 0), domine_kernel_peak(kernel, 1))
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
        guard let kernel = resources.kernel else { return }
        domine_kernel_set_mode(kernel, monoPerSpeaker ? 1 : 0, swapSides ? 1 : 0, 0)
        domine_kernel_set_test_tone(kernel, testTone.rawValue)
        domine_kernel_set_gains(kernel, leftGain, rightGain)
        domine_kernel_set_delay_ms(kernel, delayMs)
        domine_kernel_set_muted(kernel, muted ? 1 : 0)
    }
}
