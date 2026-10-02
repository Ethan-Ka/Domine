import Accelerate
import AVFoundation
import CoreAudio
import DomineDSP
import os

/// What one auto-calibration run found (SPEC section 12).
enum CalibrationOutcome: Equatable, Sendable {
    /// arrival(right) - arrival(left), in ms.
    case measured(offsetMs: Double)
    case failed(String)
    case microphoneDenied
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
    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    /// Asks for microphone access. Tests replace it.
    var requestMicAccess: @Sendable () async -> Bool = {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
    /// Runs while the mic records with the chirps on. Tests replace it to feed the IOProc.
    var wait: @MainActor () async -> Void = {
        try? await Task.sleep(for: .seconds(CalibrationController.recordSeconds))
    }
    /// Runs off the main actor. Tests replace it with a fixed result.
    var analyze: @Sendable (_ recording: [Float], _ sampleRate: Double,
                            _ rising: [Float], _ falling: [Float]) -> CalibrationResult = CalibrationController.analyzeAligned

    private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "Calibration")
    private let hal: any AudioHAL

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
    /// `setChirps` turns the kernel's click-test mode 2 on and off.
    func run(kernelRate: Double, setChirps: @MainActor (Bool) -> Void) async -> CalibrationOutcome {
        guard Self.builtInMicrophone(hal: hal) != nil else { return .failed("No built-in microphone") }
        guard await requestMicAccess() else { return .microphoneDenied }
        guard !Task.isCancelled else { return .failed("Cancelled") }
        guard let mic = Self.builtInMicrophone(hal: hal) else { return .failed("No built-in microphone") }

        let recording: [Float]
        let rate: Double
        do {
            (recording, rate) = try await record(mic: mic, kernelRate: kernelRate, setChirps: setChirps)
        } catch {
            Self.log.error("Calibration recording failed: \(error.description, privacy: .public)")
            return .failed("Could not use the microphone")
        }
        guard !Task.isCancelled else { return .failed("Cancelled") }

        let frames = Int((0.001 * (DOMINE_CHIRP_MS + DOMINE_CHIRP_TAIL_MS) * rate).rounded())
        let rising = Self.chirp(frames: frames, rate: rate, rising: true)
        let falling = Self.chirp(frames: frames, rate: rate, rising: false)
        let analyze = analyze
        let result = await Task.detached(priority: .userInitiated) {
            analyze(recording, rate, rising, falling)
        }.value
        switch result {
        case .success(let offset, _):
            return .measured(offsetMs: offset)
        case .failure(let reason):
            return .failed(reason == "Inconsistent"
                ? "Results varied. Move the Mac and try again."
                : "Too noisy. Lower background noise and try again.")
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
    /// own rate. Returns the samples and the rate they were recorded at.
    private func record(mic: AudioObjectID, kernelRate: Double,
                        setChirps: @MainActor (Bool) -> Void) async throws(EngineError) -> ([Float], Double) {
        let original = try EngineError.hal { () throws(HALError) in try hal.nominalSampleRate(of: mic) }
        var changedRate = false
        if original != kernelRate {
            let ranges = try EngineError.hal { () throws(HALError) in try hal.availableNominalSampleRates(of: mic) }
            if ranges.contains(where: { $0.contains(kernelRate) }) {
                try EngineError.hal { () throws(HALError) in try hal.setNominalSampleRate(kernelRate, of: mic) }
                changedRate = true
            }
        }
        defer {
            if changedRate {
                release("restore mic rate") { () throws(HALError) in try hal.setNominalSampleRate(original, of: mic) }
            }
        }
        let rate = changedRate ? kernelRate : original
        guard rate > 0, rate.isFinite else { throw .invalidSampleRate(rate) }

        guard let recorder = domine_recorder_create(UInt32(Self.recordSeconds * rate)) else {
            throw .kernelUnavailable
        }
        var proc: IOProcHandle?
        var started = false
        var chirpsOn = false
        func teardown() -> Bool {
            if chirpsOn { setChirps(false); chirpsOn = false }
            guard let p = proc else { return true }
            if started { release("stop mic") { () throws(HALError) in try hal.stopDevice(p) } }
            return release("destroy mic IOProc") { () throws(HALError) in try hal.destroyIOProc(p) }
        }
        do throws(EngineError) {
            proc = try EngineError.hal { () throws(HALError) in
                try hal.createIOProc(on: mic, proc: domine_recorder_ioproc, clientData: UnsafeMutableRawPointer(recorder))
            }
            try EngineError.hal { () throws(HALError) in try hal.startDevice(proc!) }
            started = true
            setChirps(true)
            chirpsOn = true
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
        return (samples, rate)
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
