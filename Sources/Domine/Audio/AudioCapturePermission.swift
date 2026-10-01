import CoreAudio
import DomineDSP
import Observation
import os

/// Requests and tracks the audio capture permission (SPEC section 8).
///
/// macOS shows the permission prompt only when the app actually reads from a
/// process tap; opening System Settings cannot grant it, and the app is not
/// listed there until it has asked. So a request briefly captures: a private,
/// non-muting global tap excluding Domine, a private aggregate holding only
/// that tap (no output sub-devices, so no speaker is touched), and an IOProc
/// in C that only notes whether any non-zero sample arrived. After `wait`
/// it tears down in exact reverse order: stop, IOProc, aggregate, tap, probe.
///
/// A tap without permission delivers silence, and silence is also what an
/// idle Mac sounds like, so a quiet probe means "not confirmed", not "denied".
@MainActor
@Observable
final class AudioCapturePermission {
    static let probeDuration: Duration = .seconds(1)

    private(set) var status: AudioCaptureStatus
    private(set) var isProbing = false

    /// Runs while the probe captures. Tests replace it to feed the IOProc.
    @ObservationIgnored var wait: @MainActor () async -> Void = {
        try? await Task.sleep(for: AudioCapturePermission.probeDuration)
    }

    private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "CapturePermission")

    @ObservationIgnored private let hal: any AudioHAL
    @ObservationIgnored private let store: SettingsStore

    private struct Resources {
        var tap: ProcessTap?
        var aggregate: AudioObjectID?
        var probe: OpaquePointer?
        var ioProc: IOProcHandle?
        var started = false
    }

    init(hal: any AudioHAL, store: SettingsStore) {
        self.hal = hal
        self.store = store
        status = store.audioCaptureWorking ? .working : .unknown
    }

    /// Runs the probe once, which makes macOS show the prompt if it has not
    /// yet. Ends `.working` if audio arrived, else `.notConfirmed` unless
    /// capture was already known to work.
    func request() async {
        guard !isProbing else { return }
        isProbing = true
        defer { isProbing = false }
        var heard = false
        do {
            heard = try await capture()
        } catch {
            Self.log.error("Capture probe failed: \(error.description, privacy: .public)")
        }
        if heard {
            markWorking()
        } else if status != .working {
            status = .notConfirmed
        }
    }

    /// Records that tap audio arrived, here or in the engine.
    func markWorking() {
        guard status != .working else { return }
        status = .working
        store.audioCaptureWorking = true
    }

    /// One probe run. Returns whether any non-zero sample arrived. Any
    /// failure unwinds what was created, in reverse, and rethrows.
    func capture() async throws(EngineError) -> Bool {
        var r = Resources()
        do throws(EngineError) {
            let own = try EngineError.hal { () throws(HALError) in try hal.ownProcessObject() }
            guard own != kAudioObjectUnknown else { throw .noOwnProcessObject }
            let tap = try EngineError.hal { () throws(HALError) in
                try hal.createProcessTap(excluding: [own], muted: false)
            }
            r.tap = tap
            let description = AggregateBuilder.probeDescription(tapUID: tap.uid)
            let aggregate = try EngineError.hal { () throws(HALError) in
                try hal.createAggregateDevice(description)
            }
            r.aggregate = aggregate
            guard let probe = domine_probe_create() else { throw .kernelUnavailable }
            r.probe = probe
            let proc = try EngineError.hal { () throws(HALError) in
                try hal.createIOProc(on: aggregate, proc: domine_probe_ioproc, clientData: UnsafeMutableRawPointer(probe))
            }
            r.ioProc = proc
            try EngineError.hal { () throws(HALError) in try hal.startDevice(proc) }
            r.started = true
            await wait()
            let heard = domine_probe_heard(probe) != 0
            teardown(r)
            return heard
        } catch {
            teardown(r)
            throw error
        }
    }

    /// Releases in reverse creation order. Errors are logged so one failure
    /// never strands the rest. The probe is freed only once no IOProc can
    /// still call into it.
    private func teardown(_ r: Resources) {
        var ioProcGone = true
        var aggregateGone = true
        if let proc = r.ioProc {
            if r.started {
                release("stop device") { () throws(HALError) in try hal.stopDevice(proc) }
            }
            ioProcGone = release("destroy IOProc") { () throws(HALError) in try hal.destroyIOProc(proc) }
        }
        if let aggregate = r.aggregate {
            aggregateGone = release("destroy aggregate") { () throws(HALError) in
                try hal.destroyAggregateDevice(aggregate)
            }
        }
        if let tap = r.tap {
            release("destroy tap") { () throws(HALError) in try hal.destroyProcessTap(tap.id) }
        }
        if let probe = r.probe {
            if ioProcGone || aggregateGone {
                domine_probe_destroy(probe)
            } else {
                Self.log.fault("Probe IOProc and aggregate survived teardown; leaking the probe")
            }
        }
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
}
