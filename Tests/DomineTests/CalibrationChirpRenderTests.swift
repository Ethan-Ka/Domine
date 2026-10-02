import Foundation
import Testing
@testable import Domine

/// Calibration chirps must reach both speakers through the real C IOProc.
@MainActor
final class CalibrationChirpRenderTests {
    let hal = FakeHAL()

    @Test func chirpsReachBothPositionsWhileCalibrating() async {
        let engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero, fadeWait: { _ in })
        hal.add(EngineTests.gripA)
        hal.add(EngineTests.gripB)
        await engine.start(left: EngineTests.gripA.uid, right: EngineTests.gripB.uid)
        #expect(engine.state == .running)

        engine.calibrationChirps = true
        let frames = 4096
        var peakA: Float = 0, peakB: Float = 0
        for _ in 0..<40 {
            let input = FakeBufferList(channelsPerBuffer: [2], frames: frames)
            let out = FakeBufferList(channelsPerBuffer: [2, 2], frames: frames, fill: 0)
            hal.render(input: input, output: out)
            peakA = max(peakA, out.channel(0).map { abs($0) }.max() ?? 0)
            peakB = max(peakB, out.channel(2).map { abs($0) }.max() ?? 0)
        }
        #expect(peakA > 0.05)
        #expect(peakB > 0.05)
    }
}
