import Foundation
import Testing
@testable import Domine

struct CalibrationAnalyzerTests {
    static let sr = 44_100.0

    /// Matches the real signal: 120 ms log sweep 300 Hz to 3 kHz, Tukey 25% envelope, peak 0.3.
    static func chirp(rising: Bool) -> [Float] {
        let n = Int(0.12 * sr)
        let (f0, f1) = rising ? (300.0, 3000.0) : (3000.0, 300.0)
        let dur = Double(n) / sr
        let k = log(f1 / f0)
        let taper = 0.25 * Double(n - 1) / 2
        return (0..<n).map { i in
            let t = Double(i) / sr
            let phase = 2 * Double.pi * f0 * dur / k * (exp(t * k / dur) - 1)
            let d = Double(i)
            let edge = min(d, Double(n - 1) - d)
            let env = edge >= taper ? 1.0 : 0.5 - 0.5 * cos(Double.pi * edge / taper)
            return Float(0.3 * sin(phase) * env)
        }
    }

    /// Chirp A at 0.4 s + k, chirp B at that plus offset (per-window offsets allowed).
    static func recording(offsetsMs: [Double], gain: Float = 0.1, gainB: Float? = nil,
                          noise: Float = 0.01, seconds: Int = 5) -> [Float] {
        var rec = [Float](repeating: 0, count: Int(sr) * seconds)
        let up = chirp(rising: true), down = chirp(rising: false)
        for k in 0..<seconds {
            let a = Int(sr) * k + Int(0.4 * sr)
            let b = a + Int((offsetsMs[k % offsetsMs.count] / 1000 * sr).rounded())
            for i in 0..<up.count { rec[a + i] += up[i] * gain }
            for i in 0..<down.count { rec[b + i] += down[i] * (gainB ?? gain) }
        }
        var rng = SystemRandomNumberGenerator()
        for i in 0..<rec.count { rec[i] += Float.random(in: -noise...noise, using: &rng) }
        return rec
    }

    @Test(arguments: [0.0, 7.5, -23.0, 180.0, 300.0, -300.0])
    func recoversOffset(offset: Double) {
        let rec = Self.recording(offsetsMs: [offset])
        let r = CalibrationAnalyzer.measure(recording: rec, sampleRate: Self.sr, rising: Self.chirp(rising: true), falling: Self.chirp(rising: false))
        guard case let .success(ms, windows, _) = r else { Issue.record("expected success, got \(r)"); return }
        #expect(abs(ms - offset) < 0.1)
        #expect(windows == 5)
    }

    /// Levels are proportional to each chirp's scale: B at half of A reads -6.02 dB. The chirps do not overlap.
    @Test(arguments: [(Float(0.1), Float(0.05)), (Float(0.05), Float(0.2)), (Float(0.1), Float(0.1))])
    func levelsFollowChirpScale(scales: (Float, Float)) {
        let rec = Self.recording(offsetsMs: [200], gain: scales.0, gainB: scales.1, noise: 0.001)
        let r = CalibrationAnalyzer.measure(recording: rec, sampleRate: Self.sr, rising: Self.chirp(rising: true), falling: Self.chirp(rising: false))
        guard case let .success(_, _, levels?) = r else { Issue.record("expected levels, got \(r)"); return }
        let expected = 20 * log10(Double(scales.1 / scales.0))
        #expect(abs(levels.fallingOverRisingDb - expected) < 0.1)
    }

    @Test func oneOutlierWindowIsIgnored() {
        let rec = Self.recording(offsetsMs: [5, 5, 5, 40, 5, 5, 5], seconds: 7)
        let r = CalibrationAnalyzer.measure(recording: rec, sampleRate: Self.sr, rising: Self.chirp(rising: true), falling: Self.chirp(rising: false))
        guard case let .success(ms, windows, _) = r else { Issue.record("expected success, got \(r)"); return }
        #expect(abs(ms - 5) < 0.1)
        #expect(windows == 6)
    }

    @Test func trimsCutToTheQuietest() {
        let trims = ChirpLevels.trims(levels: ["a": 2, "b": 1, "c": 4, "d": 50, "e": 0])
        #expect(trims["b"] == 1)
        #expect(trims["a"] == 0.5)
        #expect(trims["c"] == 0.25)
        #expect(trims["d"] == ChirpLevels.minTrim) // -34 dB floors at -20 dB
        #expect(trims["e"] == nil) // a failed capture is left unchanged
    }

    @Test func stereoBalanceCutsTheLouderSide() {
        #expect(AppModel.calibratedBalance(levels: ChirpLevels(rising: 2, falling: 1)) == 0.5)
        #expect(AppModel.calibratedBalance(levels: ChirpLevels(rising: 1, falling: 4)) == -0.75)
        #expect(AppModel.calibratedBalance(levels: ChirpLevels(rising: 1, falling: 1)) == 0)
        #expect(AppModel.calibratedBalance(levels: ChirpLevels(rising: 0, falling: 1)) == nil)
    }

    @Test func pureNoiseFails() {
        let rec = Self.recording(offsetsMs: [0], gain: 0, noise: 0.05)
        let r = CalibrationAnalyzer.measure(recording: rec, sampleRate: Self.sr, rising: Self.chirp(rising: true), falling: Self.chirp(rising: false))
        #expect(r == .failure(reason: "Too noisy"))
    }

    /// Half the windows disagree: no majority, so the run fails.
    @Test func halfBadWindowsFail() {
        let rec = Self.recording(offsetsMs: [0, 10], seconds: 6)
        let r = CalibrationAnalyzer.measure(recording: rec, sampleRate: Self.sr, rising: Self.chirp(rising: true), falling: Self.chirp(rising: false))
        #expect(r == .failure(reason: "Inconsistent"))
    }

    @Test func delaySign() {
        #expect(CalibrationAnalyzer.delaySetting(forOffsetMs: -23.4) == 23)
        #expect(CalibrationAnalyzer.delaySetting(forOffsetMs: 7.5) == -8)
        #expect(CalibrationAnalyzer.delaySetting(forOffsetMs: 0) == 0)
    }
}
