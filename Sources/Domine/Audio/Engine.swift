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
    var swapSides = false { didSet { applyControls() } }
    var testTone: TestTone = .off { didSet { applyControls() } }
    var leftGain: Float = 1 { didSet { applyControls() } }
    var rightGain: Float = 1 { didSet { applyControls() } }
    /// Positive delays the right speaker, negative the left (SPEC section 4).
    var delayMs: Float = 0 { didSet { applyControls() } }
    /// Fades the output out (or back in) over 50 ms in the kernel.
    var muted = false { didSet { applyControls() } }
    let monoPerSpeaker = true
    /// Process objects the next tap leaves out besides Domine itself
    /// (SPEC 3b). Empty until excluded apps are resolved to processes.
    var excludedProcesses: [AudioObjectID] = []

    var isKernelAllocated: Bool { resources.kernel != nil }

    private struct Resources {
        var tap: ProcessTap?
        var aggregate: AudioObjectID?
        var kernel: OpaquePointer?
        var ioProc: IOProcHandle?
        var deviceStarted = false
    }

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

    /// The aggregate may publish its streams a moment after creation, so the
    /// layout read is retried up to `layoutAttempts` times.
    init(hal: any AudioHAL, layoutAttempts: Int = 10, layoutRetryDelay: Duration = .milliseconds(50)) {
        self.hal = hal
        self.taps = TapController(hal: hal)
        self.layoutAttempts = max(1, layoutAttempts)
        self.layoutRetryDelay = layoutRetryDelay
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
            try createTapAndAggregate(a: a, b: b)
            guard let layout = try await readLayout(a: a, b: b, generation: current),
                  current == generation else { return }
            try startIO(layout: layout)
            self.layout = layout
            state = .running
            Self.log.info("Running: A \(a.uid, privacy: .public), B \(b.uid, privacy: .public), layout \(String(describing: layout), privacy: .public)")
        } catch {
            guard current == generation else { return }
            teardown()
            state = .error(error.description)
            Self.log.error("Start failed: \(error.description, privacy: .public)")
        }
    }

    func stop() {
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
        let tap = try taps.create(alsoExcluding: excludedProcesses)
        resources.tap = tap
        let format = try EngineError.hal { () throws(HALError) in try hal.tapFormat(of: tap.id) }
        Self.log.info("Tap \(tap.uid, privacy: .public): \(format.mChannelsPerFrame) ch at \(format.mSampleRate) Hz")
        let description = AggregateBuilder.description(uidA: a.uid, uidB: b.uid, tapUID: tap.uid)
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

    // MARK: - Teardown

    /// Releases everything in `resources`, in reverse creation order. Errors
    /// are logged, not thrown, so one failure never strands the rest.
    private func teardown() {
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
