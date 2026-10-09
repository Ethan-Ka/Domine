import Foundation
import Testing
@testable import Domine

/// The background-noise check of auto-calibration (SPEC 12) on synthetic captures.
struct CalibrationNoiseCheckTests {
    typealias A = CalibrationAnalyzerTests
    static let up = A.chirp(rising: true)
    static let down = A.chirp(rising: false)

    /// Half a second of the silent room: uniform noise of the given peak.
    static func room(_ peak: Float) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        return (0..<Int(0.5 * A.sr)).map { _ in Float.random(in: -peak...peak, using: &rng) }
    }

    static func outcome(gainB: Float = 0.1, recordingNoise: Float = 0.001, roomNoise: Float) -> CalibrationOutcome {
        let rec = A.recording(offsetsMs: [200], gain: 0.1, gainB: gainB, noise: recordingNoise)
        let result = CalibrationAnalyzer.measure(recording: rec, sampleRate: A.sr, rising: up, falling: down)
        let floor = CalibrationNoiseCheck.noiseFloor(room(roomNoise), rising: up, falling: down)
        return CalibrationController.outcome(result, noiseFloor: floor)
    }

    /// The chirps are clean, but the room before them was loud: under 20 dB SNR.
    @Test func loudNoiseFloorFails() {
        #expect(Self.outcome(roomNoise: 0.5) == .tooNoisy)
    }

    @Test func quietRoomPasses() {
        guard case .measured(let offset, let levels?) = Self.outcome(roomNoise: 0.001) else {
            Issue.record("expected a measurement")
            return
        }
        #expect(abs(offset - 200) < 0.1)
        #expect(abs(levels.fallingOverRisingDb) < 0.1)
    }

    /// The falling speaker plays nothing: it, not the room, is named.
    @Test func silentSpeakerIsTooQuiet() {
        #expect(Self.outcome(gainB: 0, recordingNoise: 0.05, roomNoise: 0.001) == .speakerTooQuiet(rising: false))
    }

    @Test func verdictBlamesTheQuietSpeakerOnlyWhenTheOtherIsClear() {
        // 46 dB and 6 dB over the floor: the second speaker is too quiet.
        #expect(CalibrationNoiseCheck.verdict(levels: ChirpLevels(rising: 100, falling: 1), noiseFloor: 0.5) == .tooQuiet(rising: false))
        #expect(CalibrationNoiseCheck.verdict(levels: ChirpLevels(rising: 1, falling: 100), noiseFloor: 0.5) == .tooQuiet(rising: true))
        // 26 dB and 12 dB: neither is clear of the room, so blame the noise.
        #expect(CalibrationNoiseCheck.verdict(levels: ChirpLevels(rising: 10, falling: 2), noiseFloor: 0.5) == .tooNoisy)
        #expect(CalibrationNoiseCheck.verdict(levels: ChirpLevels(rising: 10, falling: 10), noiseFloor: 0.5) == .ok)
    }
}
