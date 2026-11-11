import Foundation
import Testing
@testable import Domine

struct DelayNudgeTests {
    @Test func nudgesByStep() {
        #expect(TuningState.nudge(0, by: 1, in: -50...50) == 1)
        #expect(TuningState.nudge(10, by: -5, in: -50...50) == 5)
        #expect(TuningState.nudge(-3, by: 5, in: -50...50) == 2)
    }

    @Test func clampsToRange() {
        #expect(TuningState.nudge(48, by: 5, in: -50...50) == 50)
        #expect(TuningState.nudge(-49, by: -5, in: -50...50) == -50)
        #expect(TuningState.nudge(296, by: 5, in: -300...300) == 300)
    }

    @Test func labelsMatchDirection() {
        #expect(TuningSheet.nudgeLabel(-1) == "Delay 1 millisecond more on the left")
        #expect(TuningSheet.nudgeLabel(5) == "Delay 5 milliseconds more on the right")
        #expect(TuningSheet.nudgeLabel(-0.5) == "Delay 0.5 milliseconds more on the left")
        #expect(TuningSheet.nudgeTitle(-0.5) == "\u{2212}0.5")
        #expect(TuningSheet.nudgeTitle(20) == "+20")
    }

    @Test func stepSizes() {
        #expect(DelayNudgeSteps.fine.small == 0.5 && DelayNudgeSteps.fine.large == 2)
        #expect(DelayNudgeSteps.normal.small == 1 && DelayNudgeSteps.normal.large == 5)
        #expect(DelayNudgeSteps.coarse.small == 5 && DelayNudgeSteps.coarse.large == 20)
        #expect(DelayNudgeSteps.fine.buttonSteps == [-2, -0.5, 0.5, 2])
        #expect(DelayNudgeSteps.normal.buttonSteps == [-5, -1, 1, 5])
        #expect(DelayNudgeSteps.coarse.buttonSteps == [-20, -5, 5, 20])
        #expect(DelayNudgeSteps.fine.menuTitle == "Fine (0.5 and 2 ms)")
        #expect(DelayNudgeSteps.coarse.menuTitle == "Coarse (5 and 20 ms)")
    }

    @Test func halfMillisecondNudges() {
        #expect(TuningState.nudge(4, by: 0.5, in: -300...300) == 4.5)
        #expect(TuningState.nudge(-0.5, by: 0.5, in: -300...300) == 0)
        #expect(TuningState.nudge(299.5, by: 2, in: -300...300) == 300)
    }

    @Test func roundsToHalfMillisecond() {
        #expect(TuningState.roundedDelay(4.3) == 4.5)
        #expect(TuningState.roundedDelay(4.2) == 4)
        #expect(TuningState.roundedDelay(-4.74) == -4.5)
        #expect(TuningState.msText(4.5) == "4.5")
        #expect(TuningState.msText(4) == "4")
    }

    @Test func readoutShowsHalfMilliseconds() {
        #expect(TuningState.delayReadout(4.5) == "Right +4.5 ms")
        #expect(TuningState.delayReadout(-0.5) == "Left +0.5 ms")
        #expect(TuningState.delayReadout(12) == "Right +12 ms")
    }

    @MainActor @Test func modelRoundsAndClampsDelay() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let model = AppModel(hal: FakeHAL(), defaults: defaults, services: FakeSystem().services)
        model.setDelayMs(4.3)
        #expect(model.pairSettings.delayMs == 4.5)
        #expect(model.tuningState.delayReadout == "Right +4.5 ms")
        model.setDelayMs(-1000)
        #expect(model.pairSettings.delayMs == -300)
        model.setDelayMs(301)
        #expect(model.pairSettings.delayMs == 300)
    }

    @MainActor @Test func stepChoiceIsSaved() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(SettingsStore(defaults: defaults).delayNudgeSteps == .normal)
        let model = AppModel(hal: FakeHAL(), defaults: defaults, services: FakeSystem().services)
        model.openTuning()
        #expect(model.tuningState.nudgeSteps == .normal)
        model.tuningActions.setNudgeSteps(.fine)
        #expect(model.tuningState.nudgeSteps == .fine)
        #expect(SettingsStore(defaults: defaults).delayNudgeSteps == .fine)
        let reopened = AppModel(hal: FakeHAL(), defaults: defaults, services: FakeSystem().services)
        reopened.openTuning()
        #expect(reopened.tuningState.nudgeSteps == .fine)
        defaults.set("bogus", forKey: "Domine.delayNudgeSteps")
        #expect(SettingsStore(defaults: defaults).delayNudgeSteps == .normal)
    }
}
