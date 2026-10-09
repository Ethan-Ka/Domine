import Accelerate
import AVFoundation
import CoreAudio
import DomineDSP
import os

/// What one auto-calibration run found (SPEC section 12).
enum CalibrationOutcome: Equatable, Sendable {
    /// arrival(right) - arrival(left), in ms, and how loud each chirp
    /// arrived (nil when not measured).
    case measured(offsetMs: Double, levels: ChirpLevels? = nil)
    case failed(String)
    case microphoneDenied
    /// The room is too loud to measure (noise check, SPEC 12).
    case tooNoisy
    /// One speaker was too quiet to measure: the rising (left, s_k) one or
    /// the falling (right, s(k+1)) one.
    case speakerTooQuiet(rising: Bool)

    static let tooNoisyMessage = "Too much background noise. Make the room quieter and try again."
}

/// Records the kernel's calibration chirps through the Mac's built-in
/// microphone and measures the arrival offset between the two speakers.
///
/// Only the built-in microphone is ever opened: opening a Bluetooth input
/// would switch the speaker to its headset profile (CLAUDE.md). The recorder
/// IOProc lives only for the recording and is torn down in reverse order:
/// stop, destroy IOProc, free the recorder, restore the mic's rate.
@MainActor
final class CalibrationController {
    static let recordSeconds = 5.5
    /// The silent stretch recorded before the chirps for the noise check.
    static let quietSeconds = 0.7
    /// The start of the silent stretch that is skipped (mute fade, settling).
    static let quietSkipSeconds = 0.15
    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    /// Asks for microphone access. Tests replace it.
    var requestMicAccess: @Sendable () async -> Bool = {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
    /// Runs while the mic records the silent room before the chirps. Tests replace it.
    var waitQuiet: @MainActor () async -> Void = {
        try? await Task.sleep(for: .seconds(CalibrationController.quietSeconds))
    }
    /// Runs while the mic records with the chirps on. Tests replace it to feed the IOProc.
    var wait: @MainActor () async -> Void = {
        try? await Task.sleep(for: .seconds(CalibrationController.recordSeconds))
    }
    /// Runs off the main actor. Tests replace it with a fixed result.
    var analyze: @Sendable (_ recording: [Float], _ sampleRate: Double,
                            _ rising: [Float], _ falling: [Float]) -> CalibrationResult = CalibrationController.analyzeAligned

    private nonisolated static let log = Logger(subsystem: "com.ethankawley.Domine", category: "Calibration")
    private let hal: any AudioHAL
    /// Sheet line for the setup step that is running; read when `record` throws.
    private var setupFailure = "Could not use the microphone"

    init(hal: any AudioHAL) {
        self.hal = hal
    }

    /// The built-in microphone: built-in transport with at least one input
    /// channel. Never a Bluetooth or other external input.
    static func builtInMicrophone(hal: any AudioHAL) -> AudioObjectID? {
        guard let ids = try? hal.deviceIDs() else { return nil }
        return ids.first { id in
            guard (try? hal.transportType(of: id)) == kAudioDeviceTransportTypeBuiltIn,
                  let inputs = try? hal.streamChannels(of: id, scope: .input) else { return false }
            return inputs.reduce(0, +) > 0
        }
    }

    var isAvailable: Bool { Self.builtInMicrophone(hal: hal) != nil }

    /// One run: permission, recording with chirps on, analysis.
    /// `setChirps` turns the kernel's click-test mode 2 on and off. `label`
    /// names the pair in the log and the saved recording.
    /// `setSilent` mutes program audio for the noise check before the chirps.
    func run(kernelRate: Double, label: String = "stereo",
             setSilent: @MainActor (Bool) -> Void = { _ in },
             setChirps: @MainActor (Bool) -> Void) async -> CalibrationOutcome {
        guard Self.builtInMicrophone(hal: hal) != nil else {
            Self.log.error("No built-in microphone")
            return .failed("No built-in microphone")
        }
        let granted = await requestMicAccess()
        Self.log.info("Microphone permission granted: \(granted, privacy: .public)")
        guard granted else { return .microphoneDenied }
        guard !Task.isCancelled else { return .failed("Cancelled") }
        guard let mic = Self.builtInMicrophone(hal: hal) else { return .failed("No built-in microphone") }

        let recording: [Float]
        let rate: Double
        let quietFrames: Int
        do {
            (recording, rate, quietFrames) = try await record(mic: mic, kernelRate: kernelRate,
                                                             setSilent: setSilent, setChirps: setChirps)
        } catch {
            let line = setupFailure
            Self.log.error("Calibration setup failed: \(line, privacy: .public): \(error.description, privacy: .public)")
            return .failed(line)
        }
        guard !Task.isCancelled else { return .failed("Cancelled") }

        Self.log.info("Recorded \(recording.count, privacy: .public) frames at \(rate, privacy: .public) Hz, \(quietFrames, privacy: .public) of them quiet")
        let frames = Int((0.001 * (DOMINE_CHIRP_MS + DOMINE_CHIRP_TAIL_MS) * rate).rounded())
        let rising = Self.chirp(frames: frames, rate: rate, rising: true)
        let falling = Self.chirp(frames: frames, rate: rate, rising: false)
        let analyze = analyze
        let skipFrames = Int(Self.quietSkipSeconds * rate)
        Self.log.info("Analyzing \(label, privacy: .public)")
        let (result, noiseFloor) = await Task.detached(priority: .userInitiated) {
            let split = min(quietFrames, recording.count)
            let skip = min(skipFrames, split)
            let noise = Array(recording[skip..<split])
            let floor = CalibrationNoiseCheck.noiseFloor(noise, rising: rising, falling: falling)
            return (analyze(Array(recording[split...]), rate, rising, falling), floor)
        }.value
        Self.log.info("Analyzer result for \(label, privacy: .public): \(String(describing: result), privacy: .public)")
        let outcome = Self.outcome(result, noiseFloor: noiseFloor, label: label)
        var failed = true
        if case .measured = outcome { failed = false }
        sessionRecordings.append(.init(label: label, samples: recording, sampleRate: rate, failed: failed))
        return outcome
    }

    /// The recordings of the calibration run in progress, kept in memory
    /// until `endSession` knows whether the run failed.
    private var sessionRecordings: [CalibrationRecordingArchive.Recording] = []

    /// Starts a calibration run (one or more `run` calls).
    func beginSession() {
        sessionRecordings = []
    }

    /// Ends the run: a failed run's recordings replace whatever the log
    /// folder held; a successful one empties it; a cancelled one leaves it.
    /// The files are written off the main actor.
    func endSession(failed: Bool, cancelled: Bool = false) {
        let recordings = sessionRecordings
        sessionRecordings = []
        guard !cancelled else { return }
        Task.detached(priority: .utility) {
            if failed {
                CalibrationRecordingArchive.replace(with: recordings)
            } else {
                CalibrationRecordingArchive.clear()
            }
        }
    }

    /// Turns the analysis and the noise floor into an outcome (SPEC 12).
    nonisolated static func outcome(_ result: CalibrationResult, noiseFloor: Double?, label: String = "") -> CalibrationOutcome {
        switch result {
        case .success(let offset, _, let levels):
            guard let levels, let noiseFloor else { return .measured(offsetMs: offset, levels: levels) }
            let floorDb = 20 * log10(noiseFloor)
            let a = CalibrationNoiseCheck.snrDb(level: levels.rising, noiseFloor: noiseFloor)
            let b = CalibrationNoiseCheck.snrDb(level: levels.falling, noiseFloor: noiseFloor)
            log.info("\(label, privacy: .public): noise floor \(floorDb, privacy: .public) dB, SNR rising \(a, privacy: .public) dB, falling \(b, privacy: .public) dB")
            switch CalibrationNoiseCheck.verdict(levels: levels, noiseFloor: noiseFloor) {
            case .ok: return .measured(offsetMs: offset, levels: levels)
            case .tooNoisy: return .tooNoisy
            case .tooQuiet(let rising): return .speakerTooQuiet(rising: rising)
            }
        case .failure(let reason):
            if let noiseFloor { log.info("\(label, privacy: .public): noise floor \(20 * log10(noiseFloor), privacy: .public) dB") }
            switch reason {
            case "Inconsistent": return .failed("Results varied. Move the Mac and try again.")
            case CalibrationAnalyzer.weakRising: return .speakerTooQuiet(rising: true)
            case CalibrationAnalyzer.weakFalling: return .speakerTooQuiet(rising: false)
            default: return .tooNoisy
            }
        }
    }

    private static func chirp(frames: Int, rate: Double, rising: Bool) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        out.withUnsafeMutableBufferPointer { buf in
            domine_calibration_chirp(buf.baseAddress!, UInt32(frames), rate, rising ? 1 : 0)
        }
        return out
    }

    /// Records at the kernel rate when the mic supports it, else at the mic's
    /// own rate. First records the room with program audio muted (noise
    /// check), then with the chirps on. Returns the samples, the rate they
    /// were recorded at, and how many leading frames are the quiet room.
    private func record(mic: AudioObjectID, kernelRate: Double,
                        setSilent: @MainActor (Bool) -> Void,
                        setChirps: @MainActor (Bool) -> Void) async throws(EngineError) -> ([Float], Double, Int) {
        setupFailure = "Could not read the microphone rate"
        let original = try EngineError.hal { () throws(HALError) in try hal.nominalSampleRate(of: mic) }
        var changedRate = false
        if original != kernelRate {
            let ranges = try EngineError.hal { () throws(HALError) in try hal.availableNominalSampleRates(of: mic) }
            if ranges.contains(where: { $0.contains(kernelRate) }) {
                setupFailure = "Could not set the microphone rate"
                do throws(EngineError) {
                    try EngineError.hal { () throws(HALError) in try hal.setNominalSampleRate(kernelRate, of: mic) }
                } catch {
                    Self.log.error("Mic rate change failed: \(error.description, privacy: .public)")
                    throw error
                }
                Self.log.info("Mic rate changed to \(kernelRate, privacy: .public) Hz")
                changedRate = true
            }
        }
        defer {
            if changedRate {
                release("restore mic rate") { () throws(HALError) in try hal.setNominalSampleRate(original, of: mic) }
            }
        }
        let rate = changedRate ? kernelRate : original
        let micUID = (try? hal.uid(of: mic)) ?? "?"
        Self.log.info("Mic \(micUID, privacy: .public) rate \(rate, privacy: .public) Hz, was \(original, privacy: .public)")
        setupFailure = "Could not use the microphone"
        guard rate > 0, rate.isFinite else { throw .invalidSampleRate(rate) }

        guard let recorder = domine_recorder_create(UInt32((Self.recordSeconds + Self.quietSeconds) * rate)) else {
            Self.log.error("Recorder allocation failed")
            throw .kernelUnavailable
        }
        var proc: IOProcHandle?
        var started = false
        var chirpsOn = false
        var silent = false
        var quietFrames = 0
        func teardown() -> Bool {
            if silent { setSilent(false); silent = false }
            if chirpsOn { setChirps(false); chirpsOn = false; Self.log.info("Chirps off") }
            guard let p = proc else { return true }
            if started { release("stop mic") { () throws(HALError) in try hal.stopDevice(p) } }
            return release("destroy mic IOProc") { () throws(HALError) in try hal.destroyIOProc(p) }
        }
        do throws(EngineError) {
            setupFailure = "Could not set up the microphone"
            proc = try EngineError.hal { () throws(HALError) in
                try hal.createIOProc(on: mic, proc: domine_recorder_ioproc, clientData: UnsafeMutableRawPointer(recorder))
            }
            Self.log.info("Mic IOProc created")
            setupFailure = "Could not start the microphone"
            try EngineError.hal { () throws(HALError) in try hal.startDevice(proc!) }
            started = true
            Self.log.info("Mic IOProc started")
            setSilent(true)
            silent = true
            await waitQuiet()
            quietFrames = Int(domine_recorder_frames_written(recorder))
            setSilent(false)
            silent = false
            setChirps(true)
            chirpsOn = true
            Self.log.info("Chirps on")
            await wait()
        } catch {
            if teardown() { domine_recorder_destroy(recorder) }
            throw error
        }
        let gone = teardown()
        let count = Int(domine_recorder_frames_written(recorder))
        var samples = [Float](repeating: 0, count: count)
        samples.withUnsafeMutableBufferPointer { buf in
            _ = domine_recorder_copy(recorder, buf.baseAddress!, UInt32(count))
        }
        if gone {
            domine_recorder_destroy(recorder)
        } else {
            Self.log.fault("Mic IOProc survived teardown; leaking the recorder")
        }
        return (samples, rate, quietFrames)
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

    /// Shifts the recording so the strongest rising chirp lands 30% into its
    /// analysis window. Both chirps of one repeat then fall in the same window
    /// for any offset within the delay range. Then runs CalibrationAnalyzer.
    nonisolated static func analyzeAligned(recording: [Float], sampleRate: Double,
                                           rising: [Float], falling: [Float]) -> CalibrationResult {
        let window = Int(sampleRate * DOMINE_CLICK_PERIOD_MS / 1000)
        guard window > 0, !rising.isEmpty, recording.count >= window else {
            return CalibrationAnalyzer.measure(recording: recording, sampleRate: sampleRate,
                                               rising: rising, falling: falling)
        }
        let n = recording.count
        let padded = recording + [Float](repeating: 0, count: rising.count - 1)
        var corr = [Float](repeating: 0, count: n)
        vDSP_conv(padded, 1, rising, 1, &corr, 1, vDSP_Length(n), vDSP_Length(rising.count))
        var maxVal: Float = 0
        var maxIdx: vDSP_Length = 0
        vDSP_maxvi(corr, 1, &maxVal, &maxIdx, vDSP_Length(n))
        let target = window * 3 / 10
        let shift = ((Int(maxIdx) - target) % window + window) % window
        return CalibrationAnalyzer.measure(recording: Array(recording.dropFirst(shift)), sampleRate: sampleRate,
                                           rising: rising, falling: falling,
                                           period: DOMINE_CLICK_PERIOD_MS / 1000)
    }
}
