import Foundation
import Testing
@testable import Domine

private func close(_ a: Float, _ b: Float, tolerance: Float = 1e-6) -> Bool {
    abs(a - b) <= tolerance
}

struct MeterBallisticsTests {
    // MARK: dB mapping

    @Test func fullScaleMapsToOne() {
        #expect(MeterBallistics.displayLevel(peak: 1) == 1)
        #expect(MeterBallistics.displayLevel(peak: 2.5) == 1)
        #expect(MeterBallistics.displayLevel(peak: .infinity) == 1)
    }

    @Test func floorMapsToZero() {
        // -60 dBFS is 0.001 linear; Float(0.001) is within rounding of the floor.
        #expect(close(MeterBallistics.displayLevel(peak: 0.001), 0))
        #expect(MeterBallistics.displayLevel(peak: 0.0001) == 0)
        #expect(MeterBallistics.displayLevel(peak: 0) == 0)
    }

    @Test func midpointIsMinus30dB() {
        // -30 dBFS = 10^(-1.5) = 0.0316227766
        #expect(close(MeterBallistics.displayLevel(peak: 0.0316227766), 0.5))
        // -20 dBFS = 0.1 -> 40 / 60
        #expect(close(MeterBallistics.displayLevel(peak: 0.1), 2.0 / 3.0))
        // -6.0206 dBFS = 0.5 -> (60 - 6.0206) / 60
        #expect(close(MeterBallistics.displayLevel(peak: 0.5), Float((60 - 20 * log10(2.0)) / 60)))
    }

    @Test func nanAndNegativePeaksAreZero() {
        var b = MeterBallistics()
        #expect(b.update(peak: .nan, dt: 1.0 / 30) == 0)
        #expect(b.update(peak: -0.5, dt: 1.0 / 30) == 0)
        #expect(b.update(peak: -.infinity, dt: 1.0 / 30) == 0)
        #expect(MeterBallistics.displayLevel(peak: .nan) == 0)
        #expect(MeterBallistics.displayLevel(peak: -1) == 0)
    }

    // MARK: Ballistics

    @Test func attackIsInstant() {
        var b = MeterBallistics()
        #expect(b.update(peak: 1, dt: 0) == 1)
        var c = MeterBallistics()
        #expect(close(c.update(peak: 0.1, dt: 1.0 / 30), 2.0 / 3.0))
        #expect(c.update(peak: 1, dt: 1.0 / 30) == 1)
    }

    @Test func decaysAtTwentyDBPerSecond() {
        #expect(MeterBallistics.defaultDecayDBPerSecond == 20)
        var b = MeterBallistics()
        _ = b.update(peak: 1, dt: 0)
        // Half a second at 20 dB/s = 10 dB = 10/60 of the scale.
        #expect(close(b.update(peak: 0, dt: 0.5), 5.0 / 6.0))
    }

    @Test func decayAfterNTicksAt30Hz() {
        var b = MeterBallistics()
        _ = b.update(peak: 1, dt: 0)
        var level: Float = 1
        for _ in 0..<15 {
            level = b.update(peak: 0, dt: 1.0 / 30)
        }
        // 15 ticks = 0.5 s = 10 dB below full scale.
        #expect(close(level, 5.0 / 6.0, tolerance: 1e-5))
        for _ in 0..<45 {
            level = b.update(peak: 0, dt: 1.0 / 30)
        }
        // 60 ticks = 2 s = 40 dB below full scale.
        #expect(close(level, 1.0 / 3.0, tolerance: 1e-5))
    }

    @Test func decayStopsAtCurrentTarget() {
        var b = MeterBallistics()
        _ = b.update(peak: 1, dt: 0)
        // Target is -20 dBFS (2/3). 2 s of decay alone would reach 1/3, so the
        // level must hold at the target instead of falling below it.
        #expect(close(b.update(peak: 0.1, dt: 2), 2.0 / 3.0))
    }

    @Test func neverBelowZeroOrAboveOne() {
        var b = MeterBallistics()
        #expect(b.update(peak: 100, dt: 1) == 1)
        #expect(b.update(peak: 0, dt: 1000) == 0)
        #expect(b.update(peak: 0, dt: 1.0 / 30) == 0)
        for peak: Float in [0, 0.001, 0.01, 0.5, 1, 4, .nan, -1] {
            let level = b.update(peak: peak, dt: 0.1)
            #expect(level >= 0 && level <= 1)
        }
    }

    @Test func negativeOrNaNDtDoesNotDecay() {
        var b = MeterBallistics()
        _ = b.update(peak: 1, dt: 0)
        #expect(b.update(peak: 0, dt: -1) == 1)
        #expect(b.update(peak: 0, dt: .nan) == 1)
    }

    @Test func resetClearsLevel() {
        var b = MeterBallistics()
        _ = b.update(peak: 1, dt: 0)
        b.reset()
        #expect(b.level == 0)
    }

    // MARK: Segments

    @Test func litSegmentsAtBoundaries() {
        #expect(MeterBallistics.litSegments(level: 0) == 0)
        #expect(MeterBallistics.litSegments(level: 0.0624) == 0)
        #expect(MeterBallistics.litSegments(level: 0.0625) == 1)
        #expect(MeterBallistics.litSegments(level: 0.5) == 8)
        #expect(MeterBallistics.litSegments(level: 0.9374) == 14)
        #expect(MeterBallistics.litSegments(level: 0.9375) == 15)
        #expect(MeterBallistics.litSegments(level: 1) == 16)
        #expect(MeterBallistics.litSegments(level: 1.5) == 16)
        #expect(MeterBallistics.litSegments(level: -0.5) == 0)
        #expect(MeterBallistics.litSegments(level: .nan) == 0)
        #expect(MeterBallistics.litSegments(level: 0.5, count: 10) == 5)
        #expect(MeterBallistics.litSegments(level: 1, count: 0) == 0)
    }

    @Test func bandPerSegmentIndex() {
        for i in 1...11 { #expect(MeterBand(segment: i) == .green) }
        for i in 12...14 { #expect(MeterBand(segment: i) == .yellow) }
        for i in 15...16 { #expect(MeterBand(segment: i) == .red) }
        #expect(MeterBand(segment: 0) == .green)
        #expect(MeterBand(segment: 17) == .red)
    }
}

@MainActor
struct MeterModelTests {
    @Test func startsAtZero() {
        let model = MeterModel()
        #expect(model.levelA == 0)
        #expect(model.levelB == 0)
        #expect(!model.isRunning)
    }

    @Test func tickWithoutReaderDoesNothing() {
        let model = MeterModel()
        model.tick(dt: 1.0 / 30)
        #expect(model.levelA == 0)
        #expect(model.levelB == 0)
    }

    @Test func tickRunsBallisticsPerPosition() {
        let model = MeterModel()
        var peaks: (Float, Float) = (1, 0.1)
        model.start { peaks }
        #expect(model.isRunning)

        model.tick(dt: 1.0 / 30)
        #expect(model.levelA == 1)
        #expect(close(model.levelB, 2.0 / 3.0))

        peaks = (0, 0)
        model.tick(dt: 0.5)
        #expect(close(model.levelA, 5.0 / 6.0))
        #expect(close(model.levelB, 0.5))

        model.stop()
    }

    @Test func stopResetsToZero() {
        let model = MeterModel()
        model.start { (1, 1) }
        model.tick(dt: 1.0 / 30)
        #expect(model.levelA == 1)
        model.stop()
        #expect(model.levelA == 0)
        #expect(model.levelB == 0)
        #expect(!model.isRunning)
        // No reader after stop, so ticks do nothing.
        model.tick(dt: 1.0 / 30)
        #expect(model.levelA == 0)
    }

    @Test func restartDoesNotCarryOldLevel() {
        let model = MeterModel()
        model.start { (1, 1) }
        model.tick(dt: 1.0 / 30)
        model.start { (0, 0) }
        model.tick(dt: 1.0 / 30)
        #expect(model.levelA == 0)
        #expect(model.levelB == 0)
        model.stop()
    }

    @Test func pollsOnItsOwnAt30Hz() async throws {
        let model = MeterModel()
        model.start { (1, 0.1) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.levelA == 1)
        #expect(close(model.levelB, 2.0 / 3.0))
        model.stop()
    }
}
