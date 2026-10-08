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
    }
}
