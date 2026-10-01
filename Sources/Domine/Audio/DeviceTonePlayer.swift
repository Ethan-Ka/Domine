import CoreAudio
import DomineDSP
import Observation
import os

/// Plays the identification tone on one output device, without the engine:
/// an IOProc in C on that device alone writes a short sine to every channel.
/// Used by "Play tone" in the Choose Speaker sheet and by Test L / Test R
/// while routing is off. One tone at a time; a new one replaces the old.
@MainActor
@Observable
final class DeviceTonePlayer {
    static let duration: Duration = .milliseconds(1500)

    /// The device UID whose tone is playing, if any.
    private(set) var playingUID: String?

    /// Waits for the tone to finish. Tests replace it to run the IOProc.
    @ObservationIgnored var wait: @MainActor () async -> Void = {
        try? await Task.sleep(for: DeviceTonePlayer.duration + .milliseconds(150))
    }

    private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "DeviceTone")

    @ObservationIgnored private let hal: any AudioHAL
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(hal: any AudioHAL) {
        self.hal = hal
    }

    func play(uid: String) {
        stop()
        generation += 1
        let current = generation
        playingUID = uid
        task = Task { [weak self] in
            await self?.run(uid: uid)
            guard let self, self.generation == current else { return }
            self.playingUID = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        playingUID = nil
    }

    /// Creates, starts, waits, then tears down in reverse. Never throws:
    /// a tone that cannot play is logged and skipped.
    func run(uid: String) async {
        var tone: OpaquePointer?
        var proc: IOProcHandle?
        var started = false
        defer { teardown(tone: tone, proc: proc, started: started) }
        do throws(HALError) {
            let id = try hal.deviceID(forUID: uid)
            guard id != kAudioObjectUnknown else { return }
            let rate = try hal.nominalSampleRate(of: id)
            let seconds = Double(Self.duration.components.seconds)
                + Double(Self.duration.components.attoseconds) / 1e18
            guard let created = domine_tone_create(rate, seconds) else { return }
            tone = created
            proc = try hal.createIOProc(on: id, proc: domine_tone_ioproc, clientData: UnsafeMutableRawPointer(created))
            if let proc { try hal.startDevice(proc) }
            started = true
            await wait()
        } catch {
            Self.log.error("Tone on \(uid, privacy: .public) failed: \(error.description, privacy: .public)")
        }
    }

    private func teardown(tone: OpaquePointer?, proc: IOProcHandle?, started: Bool) {
        var procGone = true
        if let proc {
            if started { release("stop device") { () throws(HALError) in try hal.stopDevice(proc) } }
            procGone = release("destroy IOProc") { () throws(HALError) in try hal.destroyIOProc(proc) }
        }
        if let tone {
            if procGone {
                domine_tone_destroy(tone)
            } else {
                Self.log.fault("Tone IOProc survived teardown; leaking the tone")
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
