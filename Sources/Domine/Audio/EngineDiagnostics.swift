import CoreAudio
import Darwin
import Foundation
import DomineDSP
import os

/// Periodic timing log for a running engine. Reads the kernel's stats and the
/// aggregate's clock, latency, and overload state every `interval` and logs
/// them under category Diagnostics. Read-only: it never changes audio.
///
/// Watch with:
/// /usr/bin/log stream --style compact --predicate 'subsystem == "com.ethankawley.Domine" AND category == "Diagnostics"'
@MainActor
final class EngineDiagnostics {
    struct Device: Sendable {
        let label: String
        let uid: String
        let id: AudioObjectID
    }

    static let log = Logger(subsystem: "com.ethankawley.Domine", category: "Diagnostics")

    private let hal: any AudioHAL
    private let kernel: OpaquePointer
    private let aggregate: AudioObjectID
    private let devices: [Device]
    private let tap: ProcessTap
    private let interval: Duration
    private let secondsPerTick: Double
    private var previous: DomineKernelStats?
    private var firstIOGap: Double?
    private var firstOutputLead: Double?
    private var task: Task<Void, Never>?
    private var overloadToken: HALListenerToken?
    private let dropouts: DropoutTracker
    private var overloadsAtLastSample = 0
    private var clockReadings: [AudioObjectID: AudioTimeStamp] = [:]
    /// Rates measured with AudioDeviceGetCurrentTime, by device, for tests.
    /// Only the aggregate is measured while running.
    private(set) var lastMeasuredRates: [AudioObjectID: Double] = [:]

    /// Processor overloads reported on the aggregate since `start`.
    private(set) var overloads = 0
    /// The most recent window, for tests.
    private(set) var lastWindow: DiagnosticsWindow?

    init(hal: any AudioHAL, kernel: OpaquePointer, aggregate: AudioObjectID,
         devices: [Device], tap: ProcessTap, interval: Duration) {
        self.hal = hal
        self.kernel = kernel
        self.aggregate = aggregate
        self.devices = devices
        self.tap = tap
        self.interval = interval
        dropouts = DropoutTracker(hal: hal, devices: devices)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = timebase.denom == 0 ? 1e-9 : Double(timebase.numer) / Double(timebase.denom) * 1e-9
    }

    func start() {
        dropouts.start()
        do {
            overloadToken = try hal.addListener(.processorOverload(aggregate)) { [weak self] in
                self?.overloads += 1
            }
        } catch {
            Self.log.error("Could not listen for processor overloads: \(error.description, privacy: .public)")
        }
        var initial = DomineKernelStats()
        _ = domine_kernel_stats(kernel, &initial)
        previous = initial
        let interval = interval
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// Stops the timer and the listener. Call before the kernel is destroyed.
    func stop() {
        dropouts.stop()
        task?.cancel()
        task = nil
        overloadToken?.cancel()
        overloadToken = nil
    }

    /// Takes one sample and logs it.
    func tick() {
        let window = sample()
        logWindow(window)
        logClocks()
    }

    /// Reads the kernel stats and computes the window since the last sample.
    @discardableResult
    func sample() -> DiagnosticsWindow {
        var current = DomineKernelStats()
        _ = domine_kernel_stats(kernel, &current)
        domine_kernel_stats_reset_maxima(kernel)
        let window = DiagnosticsWindow.compute(
            previous: previous ?? DomineKernelStats(), current: current, secondsPerTick: secondsPerTick)
        previous = current
        if firstIOGap == nil { firstIOGap = window.ioGapFrames }
        if firstOutputLead == nil { firstOutputLead = window.outputLeadMs }
        lastWindow = window
        return window
    }

    private func logWindow(_ w: DiagnosticsWindow) {
        let s = previous ?? DomineKernelStats()
        let newOverloads = overloads - overloadsAtLastSample
        overloadsAtLastSample = overloads
        Self.log.info("""
            Timing: \(Self.f(w.seconds, 3), privacy: .public) s, \(Self.f(w.cyclesPerSecond, 2), privacy: .public) cycles/s, \
            \(Self.f(w.framesPerSecond, 1), privacy: .public) out frames/s, \(Self.f(w.inputFramesPerSecond, 1), privacy: .public) in frames/s, \
            effective out rate \(Self.f(w.effectiveSampleRate, 2), privacy: .public) Hz, \
            effective in rate \(Self.f(w.effectiveInputSampleRate, 2), privacy: .public) Hz, kernel rate \(s.sampleRate, privacy: .public) Hz, \
            last cycle \(s.lastFrames, privacy: .public) out frames (min \(s.lastOutputFramesMin, privacy: .public) over \(s.lastOutputBuffers, privacy: .public) buffers), \
            \(s.lastInputFrames, privacy: .public) in frames (\(s.lastInputBuffers, privacy: .public) buffers, \(s.lastInputChannels, privacy: .public) ch), \
            fifo \(s.fifoFill, privacy: .public)/\(s.fifoCapacity, privacy: .public)
            """)
        Self.log.info("""
            Input: underrun \(w.underrunFrames, privacy: .public) frames, overflow \(w.overflowFrames, privacy: .public) frames, \
            missing \(w.missingCycles, privacy: .public), short \(w.shortCycles, privacy: .public), long \(w.longCycles, privacy: .public), \
            silent \(w.silentCycles, privacy: .public) cycles, format mismatch \(w.formatMismatchCycles, privacy: .public), \
            peak \(s.maxInputPeak, privacy: .public); sample time jumps \(w.sampleTimeJumps, privacy: .public), \
            max cycle gap \(Self.f(w.maxCycleIntervalMs, 2), privacy: .public) ms, overloads \(newOverloads, privacy: .public) (total \(self.overloads, privacy: .public))
            """)
        let gapGrowth = w.ioGapFrames.flatMap { gap in firstIOGap.map { gap - $0 } }
        let leadGrowth = w.outputLeadMs.flatMap { lead in firstOutputLead.map { lead - $0 } }
        Self.log.info("""
            Latency: output lead \(Self.f(w.outputLeadMs, 2), privacy: .public) ms (growth \(Self.f(leadGrowth, 2), privacy: .public) ms), \
            input lag \(Self.f(w.inputLagMs, 2), privacy: .public) ms, \
            out minus in sample time \(Self.f(w.ioGapFrames, 0), privacy: .public) frames (growth \(Self.f(gapGrowth, 0), privacy: .public) frames)
            """)
    }

    private func logClocks() {
        let rate = read { () throws(HALError) in try self.hal.nominalSampleRate(of: self.aggregate) }
        let actual = read { () throws(HALError) in try self.hal.actualSampleRate(of: self.aggregate) }
        let buffer = read { () throws(HALError) in try self.hal.bufferFrameSize(of: self.aggregate) }
        let outLatency = read { () throws(HALError) in try self.hal.latency(of: self.aggregate, scope: .output) }
        let inLatency = read { () throws(HALError) in try self.hal.latency(of: self.aggregate, scope: .input) }
        let tapFormat = read { () throws(HALError) in try self.hal.tapFormat(of: self.tap.id) }
        var expected = "unknown"
        if case .success(let l) = outLatency, case .success(let b) = buffer, case .success(let r) = rate, r > 0 {
            expected = Self.f((Double(l.totalFrames) + Double(b)) * 1000 / r, 1) + " ms"
        }
        Self.log.info("""
            Aggregate: nominal \(Self.text(rate), privacy: .public) Hz, actual \(Self.text(actual), privacy: .public) Hz, \
            buffer \(Self.text(buffer), privacy: .public) frames, output latency \(Self.text(outLatency), privacy: .public), \
            input latency \(Self.text(inLatency), privacy: .public), expected output delay \(expected, privacy: .public); \
            tap \(Self.text(tapFormat.map(Self.describe)), privacy: .public)
            """)
        for device in devices {
            let nominal = read { () throws(HALError) in try self.hal.nominalSampleRate(of: device.id) }
            let actual = read { () throws(HALError) in try self.hal.actualSampleRate(of: device.id) }
            let latency = read { () throws(HALError) in try self.hal.latency(of: device.id, scope: .output) }
            let buffer = read { () throws(HALError) in try self.hal.bufferFrameSize(of: device.id) }
            // No measured clock here: a sub-device is not running as a
            // device of its own, so AudioDeviceGetCurrentTime on it fails
            // with kAudioHardwareNotRunningError. The aggregate's measured
            // clock below is the one that counts.
            Self.log.info("""
                Device \(device.label, privacy: .public) \(device.uid, privacy: .public): nominal \(Self.text(nominal), privacy: .public) Hz, \
                actual \(Self.text(actual), privacy: .public) Hz, \
                buffer \(Self.text(buffer), privacy: .public) frames, output latency \(Self.text(latency), privacy: .public)
                """)
        }
        Self.log.info("Aggregate measured clock \(self.measureClock(self.aggregate), privacy: .public)")
    }

    /// The device's real rate since the previous reading, from
    /// AudioDeviceGetCurrentTime (sample time over host time). Works only on
    /// a running device: the aggregate, not its sub-devices.
    func measureClock(_ device: AudioObjectID) -> String {
        let now: AudioTimeStamp
        do {
            now = try hal.currentTime(of: device)
        } catch {
            clockReadings[device] = nil
            return "error (\(error.description))"
        }
        defer { clockReadings[device] = now }
        guard let previous = clockReadings[device],
              let rate = DiagnosticsWindow.clockRate(previous: previous, current: now, secondsPerTick: secondsPerTick)
        else { return "pending" }
        lastMeasuredRates[device] = rate
        return Self.f(rate, 1) + " Hz"
    }

    /// Per-speaker overloads and disconnects since the session start.
    var dropoutCounts: DropoutCounts { dropouts.counts }

    func resetDropoutCounts() { dropouts.reset() }

    /// Reads the current values for the Debug window. Changes no audio state.
    func snapshot() -> DebugSnapshot {
        var stats = DomineKernelStats()
        _ = domine_kernel_stats(kernel, &stats)
        let speakers = devices.map { device in
            DebugSnapshot.Speaker(
                label: device.label, uid: device.uid,
                sampleRate: try? hal.nominalSampleRate(of: device.id),
                latency: try? hal.outputLatency(of: device.id))
        }
        let format = try? hal.tapFormat(of: tap.id)
        return DebugSnapshot(
            speakers: speakers,
            aggregateRate: try? hal.nominalSampleRate(of: aggregate),
            tapFormat: format.map(Self.describe),
            kernel: DebugSnapshot.Kernel(stats),
            window: lastWindow,
            dropouts: dropouts.counts)
    }

    // MARK: - Start-up log

    /// Logs the description passed to AudioHardwareCreateAggregateDevice.
    static func logAggregateDescription(_ description: [String: Any]) {
        log.info("Aggregate description: \(String(describing: description as NSDictionary), privacy: .public)")
    }

    /// Logs the layouts, formats, and kernel setup once the device started.
    static func logStartup(hal: any AudioHAL, aggregate: AudioObjectID, tap: ProcessTap, kernel: OpaquePointer, devices: [Device]) {
        for scope in [StreamScope.input, .output] {
            let channels = read { () throws(HALError) in try hal.streamChannels(of: aggregate, scope: scope) }
            let formats = read { () throws(HALError) in try hal.streamFormats(of: aggregate, scope: scope) }
            log.info("""
                Aggregate \(scope == .input ? "input" : "output", privacy: .public) streams: \
                channels \(text(channels), privacy: .public), formats \(text(formats.map { $0.map(describe) }), privacy: .public)
                """)
        }
        for device in devices {
            let formats = read { () throws(HALError) in try hal.streamFormats(of: device.id, scope: .output) }
            let rates = read { () throws(HALError) in try hal.availableNominalSampleRates(of: device.id) }
            log.info("""
                Device \(device.label, privacy: .public) \(device.uid, privacy: .public) output formats \(text(formats.map { $0.map(describe) }), privacy: .public), \
                available rates \(text(rates), privacy: .public)
                """)
        }
        let format = read { () throws(HALError) in try hal.tapFormat(of: tap.id) }
        log.info("Tap \(tap.uid, privacy: .public): \(text(format.map(describe)), privacy: .public)")
        var s = DomineKernelStats()
        _ = domine_kernel_stats(kernel, &s)
        log.info("""
            Kernel: rate \(s.sampleRate, privacy: .public) Hz, max frames \(s.maxFrames, privacy: .public), \
            in first buffer \(s.layoutInFirstBuffer, privacy: .public), A offset \(s.layoutOutA, privacy: .public), \
            B offset \(s.layoutOutB, privacy: .public), input \(s.inputChannelsPerFrame, privacy: .public) ch \
            \(s.inputNonInterleaved != 0 ? "non-interleaved" : "interleaved", privacy: .public), fifo \(s.fifoCapacity, privacy: .public) frames
            """)
    }

    // MARK: - Formatting

    static func describe(_ f: AudioStreamBasicDescription) -> String {
        let float = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return "\(f.mSampleRate) Hz \(f.mChannelsPerFrame) ch \(float ? "float" : "int")\(f.mBitsPerChannel) "
            + "\(interleaved ? "interleaved" : "non-interleaved") \(f.mBytesPerFrame) bytes/frame "
            + "format \(FourCC.string(f.mFormatID)) flags \(f.mFormatFlags)"
    }

    private static func f(_ value: Double?, _ digits: Int) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.\(digits)f", value)
    }

    private static func text<T>(_ result: Result<T, HALError>) -> String {
        switch result {
        case .success(let value): String(describing: value)
        case .failure(let error): "error (\(error.description))"
        }
    }

    private static func read<T>(_ body: () throws(HALError) -> T) -> Result<T, HALError> {
        do { return .success(try body()) } catch { return .failure(error) }
    }

    private func read<T>(_ body: () throws(HALError) -> T) -> Result<T, HALError> {
        Self.read(body)
    }
}
