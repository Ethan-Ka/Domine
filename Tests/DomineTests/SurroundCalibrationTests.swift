import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Surround auto-calibration as a ring of pairs (SPEC 12) and the measured
/// timing rule (SPEC 13.4), against the fake HAL.
@MainActor
final class SurroundCalibrationTests {
    /// The delta the next analysis returns; set by `wait` from the pair that is on.
    final class Next: @unchecked Sendable {
        var delta: Double = 0
        var fail = false
        var levels: ChirpLevels?
    }

    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let hal = FakeHAL()
    let system = FakeSystem()
    var model: AppModel!
    let next = Next()
    /// (rising, falling) kernel indexes seen during each recording.
    var pairs: [[Int]] = []

    static let devices = (1...4).map { SurroundModelTests.device($0) }

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit { UserDefaults().removePersistentDomain(forName: suiteName) }

    private var uids: [String] { Self.devices.map(\.uid) }

    /// Routes the four speakers in Surround with fake arrivals per speaker
    /// (list order) and a fake error added to each pair's delta.
    private func setUp(arrivals: [Double], errors: [Double] = [0, 0, 0, 0], failingPair: Int? = nil,
                       levels: [Double]? = nil) async {
        for device in Self.devices + [SurroundModelTests.builtIn, CalibrationControllerTests.mic] { hal.add(device) }
        SettingsStore(defaults: defaults).startWhenBothConnect = false
        let model = AppModel(hal: hal, defaults: defaults, services: system.services)
        model.start()
        self.model = model
        model.assign(uids[0], to: .frontLeft)
        model.assign(uids[1], to: .frontRight)
        model.setRoutingMode(.surround)
        model.changeSurroundSet(uids)
        await model.startRouting()
        #expect(model.engine.state == .running)

        let next = next
        model.calibration.requestMicAccess = { true }
        model.calibration.waitQuiet = {}
        model.calibration.wait = { [unowned self] in
            guard let pair = self.model.engine.surroundCalibrationPair else {
                next.fail = true
                return
            }
            let k = self.pairs.count
            self.pairs.append([pair.rising, pair.falling])
            next.fail = k == failingPair
            next.delta = arrivals[pair.falling] - arrivals[pair.rising] + errors[k]
            next.levels = levels.map { ChirpLevels(rising: $0[pair.rising], falling: $0[pair.falling]) }
        }
        model.calibration.analyze = { _, _, _, _ in
            next.fail ? .failure(reason: "Inconsistent") : .success(offsetMs: next.delta, windows: 5, levels: next.levels)
        }
    }

    private func calibrate() async {
        model.openTuning()
        model.tuningSheetActions.autoCalibrate?()
        await model.calibrationTask?.value
    }

    private func offsets() -> [Double] {
        uids.map { Double(model.surroundSettings.offsetMs(for: $0)) }
    }

    @Test func ringOfPairsSetsEveryOffset() async {
        await setUp(arrivals: [0, 12, -5, 30])
        await calibrate()
        #expect(pairs == [[0, 1], [1, 2], [2, 3], [3, 0]])
        #expect(offsets() == [30, 18, 35, 0])
        #expect(model.surroundSettings.timingMeasured)
        #expect(model.tuningSheetState.isSurroundTimingMeasured)
        #expect(model.tuningState.calibrationStatus == .done("Delays set for 4 speakers."))
        #expect(model.engine.surroundCalibrationPair == nil)
        #expect(model.engine.state == .running)
    }

    @Test func pairDeltasMatchTheRingFormula() {
        #expect(AppModel.ringOffsets(pairDeltasMs: [12, -17, 35, -30]) == [30, 18, 35, 0])
        // Any closure is spread evenly, never fatal: 40 ms takes 10 off each pair.
        #expect(AppModel.ringOffsets(pairDeltasMs: [12, -17, 75, -30]) == [40, 38, 65, 0])
        // Real runs: two Grips and a JBL Go 4 about 80 ms behind, closures 4.9 and 11.9 ms.
        #expect(AppModel.ringOffsets(pairDeltasMs: [6.04, -82.38, 81.24]) != nil)
        #expect(AppModel.ringOffsets(pairDeltasMs: [9.78, -69.94, 72.08]) != nil)
        #expect(AppModel.ringOffsets(pairDeltasMs: [.nan, 0]) == nil)
    }

    @Test func openRingIsSpreadNotFatal() async {
        await setUp(arrivals: [0, 12, -5, 30], errors: [0, 0, 40, 0])
        model.setSurroundOffset(uid: uids[2], ms: 7)
        await calibrate()
        #expect(model.tuningState.calibrationStatus == .done("Delays set for 4 speakers."))
        #expect(offsets() == [40, 38, 65, 0])
        #expect(model.surroundSettings.timingMeasured)
    }

    @Test func smallClosureErrorIsSpread() async {
        await setUp(arrivals: [0, 12, -5, 30], errors: [0, 1, 0, 0])
        await calibrate()
        let exact: [Double] = [30, 18, 35, 0]
        for (got, want) in zip(offsets(), exact) { #expect(abs(got - want) <= 1) }
        #expect(model.surroundSettings.timingMeasured)
    }

    @Test func failingPairNamesBothSpeakersAndKeepsOffsets() async {
        await setUp(arrivals: [0, 12, -5, 30], failingPair: 1)
        model.setSurroundOffset(uid: uids[0], ms: 4)
        await calibrate()
        #expect(pairs.count == 2)
        let a = model.calibrationLabel(uid: uids[1])
        let b = model.calibrationLabel(uid: uids[2])
        guard case .failed(let reason, false) = model.tuningState.calibrationStatus else {
            Issue.record("expected a failure")
            return
        }
        #expect(reason.hasPrefix("\(a) and \(b): "))
        #expect(a != b)
        #expect(offsets() == [4, 0, 0, 0])
        #expect(!model.surroundSettings.timingMeasured)
        #expect(model.engine.surroundCalibrationPair == nil)
    }

    @Test func measuredTimingIgnoresDistance() async {
        await setUp(arrivals: [0, 0, 0, 0])
        let first = model.surroundSpeakers[0]
        model.moveSurroundSpeaker(uid: first.uid, azimuth: first.azimuth, distance: 1)
        // Unmeasured: the 1 m speaker waits for the 2 m ones.
        let unmeasured = model.engine.pushedSurround?.delaysMs ?? []
        #expect(unmeasured.count == 4)
        #expect((unmeasured.first ?? 0) > 2.5)
        #expect(unmeasured.dropFirst().allSatisfy { $0 == 0 })

        model.applySurroundCalibration(uids: uids, offsetsMs: [30, 18, 35, 0])
        #expect(model.engine.pushedSurround?.delaysMs == [30, 18, 35, 0])
        // Distance still sets level: the 1 m speaker plays at half the gain.
        let gains = model.engine.pushedSurround?.gains ?? []
        #expect(gains.count == 4)
        if gains.count == 4, gains[1] > 0 { #expect(abs(gains[0] / gains[1] - 0.5) < 0.001) }
    }

    @Test func resetAndSpeakerChangesClearTheFlag() async {
        await setUp(arrivals: [0, 12, -5, 30])
        await calibrate()
        model.setSurroundOffset(uid: uids[3], ms: 5)
        #expect(model.surroundSettings.timingMeasured) // manual edits keep it
        model.tuningSheetActions.resetSurround()
        #expect(!model.surroundSettings.timingMeasured)
        #expect(offsets() == [0, 0, 0, 0])

        model.applySurroundCalibration(uids: uids, offsetsMs: [1, 2, 3, 0])
        #expect(model.surroundSettings.timingMeasured)
        model.removeSurroundSpeaker(uid: uids[3])
        #expect(!model.surroundSettings.timingMeasured)
    }

    // MARK: Levels

    @Test func ringOfPairsSetsEveryTrim() async {
        await setUp(arrivals: [0, 12, -5, 30], levels: [2, 1, 4, 50])
        await calibrate()
        let trims = uids.map { model.surroundSettings.trim(for: $0) }
        #expect(abs(trims[0] - 0.5) < 0.0001)
        #expect(trims[1] == 1)
        #expect(abs(trims[2] - 0.25) < 0.0001)
        #expect(trims[3] == Float(ChirpLevels.minTrim))
        #expect(model.surroundSettings.levelMeasured)
        #expect(model.surroundSettings.timingMeasured)
        #expect(model.tuningState.calibrationStatus == .done("Delays and levels set for 4 speakers."))
        #expect(model.tuningSheetState.surroundMeasuredNote == "Timing and levels measured with the microphone.")
    }

    @Test func timingOnlyLeavesTrimsAndNote() async {
        await setUp(arrivals: [0, 12, -5, 30])
        model.setSurroundTrim(uid: uids[0], 0.7)
        await calibrate()
        #expect(model.surroundSettings.trim(for: uids[0]) == 0.7)
        #expect(!model.surroundSettings.levelMeasured)
        #expect(model.tuningSheetState.surroundMeasuredNote == "Timing measured with the microphone; distances set level only.")
    }

    @Test func ringTrimsMath() {
        // Levels 1, 0.5, 2, 50 (s1 quietest). The rising template reads every
        // speaker 3 dB hot; each speaker is heard once rising and once
        // falling, so the bias cancels.
        let level = [1.0, 0.5, 2, 50]
        let bias = pow(10, 3.0 / 20)
        let pairs = (0..<4).map { ChirpLevels(rising: level[$0] * bias, falling: level[($0 + 1) % 4]) }
        guard let trims = AppModel.ringTrims(pairLevels: pairs) else { Issue.record("expected trims"); return }
        let want = [0.5, 1, 0.25, ChirpLevels.minTrim]
        for (got, w) in zip(trims, want) { #expect(abs(got - w) < 0.0001) }
        #expect(trims[1] == 1)
        #expect(trims.allSatisfy { $0 <= 1 && $0 >= ChirpLevels.minTrim })
        // The real run: Grip L 25.1 / 22.9 dB, Grip R 25.3 / 20.4, Go 4 27.0 / 25.4
        // (rising / falling). Chaining pair deltas left an 8.8 dB closure;
        // the means are 24.0, 22.85 and 26.2 dB.
        let db = { (x: Double) in pow(10, x / 20) }
        let real = [ChirpLevels(rising: db(25.1), falling: db(20.4)),
                    ChirpLevels(rising: db(25.3), falling: db(25.4)),
                    ChirpLevels(rising: db(27.0), falling: db(22.9))]
        guard let r = AppModel.ringTrims(pairLevels: real) else { Issue.record("expected trims"); return }
        #expect(abs(20 * log10(r[0]) - -1.15) < 0.001)
        #expect(r[1] == 1)
        #expect(abs(20 * log10(r[2]) - -3.35) < 0.001)
        #expect(AppModel.ringTrims(pairLevels: [ChirpLevels(rising: .nan, falling: 1), ChirpLevels(rising: 1, falling: 1)]) == nil)
    }

    @Test func measuredLevelsIgnoreDistanceGain() async {
        await setUp(arrivals: [0, 0, 0, 0])
        let first = model.surroundSpeakers[0]
        model.moveSurroundSpeaker(uid: first.uid, azimuth: first.azimuth, distance: 1)
        model.applySurroundCalibration(uids: uids, offsetsMs: [0, 0, 0, 0], trims: [1, 1, 1, 0.5])
        let gains = model.engine.pushedSurround?.gains ?? []
        #expect(gains.count == 4)
        // Gain is trim only: the 1 m speaker is no longer halved.
        if gains.count == 4, gains[1] > 0 {
            #expect(abs(gains[0] / gains[1] - 1) < 0.001)
            #expect(abs(gains[3] / gains[1] - 0.5) < 0.001)
        }
        #expect(gains.allSatisfy { $0 <= 1 })
        model.setSurroundTrim(uid: uids[0], 0.8)
        #expect(model.surroundSettings.levelMeasured) // manual trim edits keep it
        model.tuningSheetActions.resetSurround()
        #expect(!model.surroundSettings.levelMeasured)
        model.applySurroundCalibration(uids: uids, offsetsMs: [0, 0, 0, 0], trims: [1, 1, 1, 1])
        model.removeSurroundSpeaker(uid: uids[3])
        #expect(!model.surroundSettings.levelMeasured)
    }

    @Test func oldJSONDecodesWithoutLevelMark() throws {
        let old = #"{"speakers":[{"uid":"a","azimuth":-30,"distance":2}],"trims":{"a":0.5},"timingMeasured":true}"#
        let s = try JSONDecoder().decode(SurroundSettings.self, from: Data(old.utf8))
        #expect(!s.levelMeasured)
        #expect(s.timingMeasured)
        #expect(s.trim(for: "a") == 0.5)
        var marked = s
        marked.levelMeasured = true
        let round = try JSONDecoder().decode(SurroundSettings.self, from: JSONEncoder().encode(marked))
        #expect(round.levelMeasured)
    }
}
