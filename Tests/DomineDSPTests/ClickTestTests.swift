import DomineDSP
import Foundation
import Testing

struct ClickTestTests {
    /// 40 ms fade, 2 ms click, 1 s period at 48 kHz.
    static let fade = 1920
    static let length = 96
    static let period = 48_000

    /// Click sample n after a click starts.
    static func click(_ n: Int, sampleRate: Double = 48_000) -> Float {
        guard n >= 0, n < length else { return 0 }
        let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(length))
        return Float(DOMINE_CLICK_AMPLITUDE * window * sin(2 * Double.pi * DOMINE_CLICK_HZ * Double(n) / sampleRate))
    }

    /// The expected click train from frame 0, with the first click at `start`.
    static func train(frames: Int, start: Int, gain: Float = 1) -> [Float] {
        (0..<frames).map { f in
            guard f >= start else { return 0 }
            return click((f - start) % period) * gain
        }
    }

    static func expectClose(_ samples: [Float], _ expected: [Float], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(samples.count == expected.count, sourceLocation: sourceLocation)
        for (i, (value, want)) in zip(samples, expected).enumerated() where abs(value - want) > 1e-7 {
            Issue.record("sample \(i): got \(value), expected \(want)", sourceLocation: sourceLocation)
            return
        }
    }

    /// Runs the kernel in `chunk`-sized calls with constant program input and
    /// returns positions A and B (checking both channels of each speaker match).
    static func run(_ kernel: Kernel, frames: Int, left: Float = 0, right: Float = 0,
                    chunk: Int = 512) -> (a: [Float], b: [Float]) {
        var a: [Float] = [], b: [Float] = []
        var done = 0
        while done < frames {
            let n = min(chunk, frames - done)
            let out = TestBufferList(channelsPerBuffer: [4], frames: n)
            kernel.process(.interleaved(left: Array(repeating: left, count: n),
                                        right: Array(repeating: right, count: n)), out)
            #expect(out.channel(1) == out.channel(0))
            #expect(out.channel(3) == out.channel(2))
            a += out.channel(0)
            b += out.channel(2)
            done += n
        }
        return (a, b)
    }

    @Test func constantsMatchTheSpec() {
        #expect(Int(lround(48_000 * DOMINE_CLICK_MS / 1000)) == Self.length)
        #expect(Int(lround(48_000 * DOMINE_CLICK_PERIOD_MS / 1000)) == Self.period)
        #expect(Int(lround(48_000 * DOMINE_TONE_FADE_MS / 1000)) == Self.fade)
    }

    @Test func clicksStartAfterTheFadeAndRepeatEverySecond() {
        let kernel = Kernel()
        domine_kernel_set_click_test(kernel.raw, 1)
        let frames = Self.fade + 2 * Self.period + 200
        let (a, b) = Self.run(kernel, frames: frames, chunk: 333)
        let expected = Self.train(frames: frames, start: Self.fade)
        Self.expectClose(a, expected)
        #expect(a == b)
        #expect(a[Self.fade] == 0) // the Hann window starts at 0
        #expect(a[Self.fade + 42] < -0.45) // near the window's center, sine at -1
        #expect(a[(Self.fade + Self.length)..<(Self.fade + Self.period)].allSatisfy { $0 == 0 })
    }

    @Test func programFadesOutThenClicksReplaceItOnBothPositions() {
        let kernel = Kernel()
        domine_kernel_set_click_test(kernel.raw, 1)
        let frames = Self.fade + 500
        let (a, b) = Self.run(kernel, frames: frames, left: 0.3, right: -0.2, chunk: 100)
        let keep = (0..<Self.fade).map { 1 - Float($0) / Float(Self.fade) }
        Self.expectClose(Array(a.prefix(Self.fade)), keep.map { 0.3 * $0 })
        Self.expectClose(Array(b.prefix(Self.fade)), keep.map { -0.2 * $0 })
        let clicks = Array(Self.train(frames: frames, start: Self.fade).suffix(500))
        Self.expectClose(Array(a.suffix(500)), clicks)
        Self.expectClose(Array(b.suffix(500)), clicks)
    }

    @Test func swapDoesNotMoveTheClicks() {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 1, 1, 0)
        domine_kernel_set_click_test(kernel.raw, 1)
        let frames = Self.fade + 300
        let (a, b) = Self.run(kernel, frames: frames, left: 0.5, right: 0.1)
        let clicks = Array(Self.train(frames: frames, start: Self.fade).suffix(300))
        Self.expectClose(Array(a.suffix(300)), clicks)
        Self.expectClose(Array(b.suffix(300)), clicks)
    }

    @Test func positiveDelayPlaysTheRightClickLater() {
        let kernel = Kernel()
        domine_kernel_set_delay_ms(kernel.raw, 10) // 480 samples on B
        domine_kernel_set_click_test(kernel.raw, 1)
        let frames = Self.fade + Self.period + 1000
        let (a, b) = Self.run(kernel, frames: frames)
        Self.expectClose(a, Self.train(frames: frames, start: Self.fade))
        Self.expectClose(b, Self.train(frames: frames, start: Self.fade + 480))
    }

    @Test func negativeDelayPlaysTheLeftClickLater() {
        let kernel = Kernel()
        domine_kernel_set_delay_ms(kernel.raw, -2.5) // 120 samples on A
        domine_kernel_set_click_test(kernel.raw, 1)
        let frames = Self.fade + Self.period + 1000
        let (a, b) = Self.run(kernel, frames: frames)
        Self.expectClose(a, Self.train(frames: frames, start: Self.fade + 120))
        Self.expectClose(b, Self.train(frames: frames, start: Self.fade))
    }

    @Test func delayChangesApplyWhileClicking() {
        let kernel = Kernel()
        domine_kernel_set_click_test(kernel.raw, 1)
        _ = Self.run(kernel, frames: Self.fade + 1000)
        domine_kernel_set_delay_ms(kernel.raw, 5) // 240 samples on B
        // The next click starts at frame period - 1000 of this run.
        let frames = Self.period
        let (a, b) = Self.run(kernel, frames: frames)
        let start = Self.period - 1000
        Self.expectClose(Array(a[start...]), Self.train(frames: 1000, start: 0))
        Self.expectClose(Array(b[start...]), Self.train(frames: 1000, start: 240))
    }

    @Test func gainsApplyToTheClicks() {
        let kernel = Kernel()
        domine_kernel_set_gains(kernel.raw, 0.5, 0.25)
        domine_kernel_set_click_test(kernel.raw, 1)
        let frames = Self.fade + 300
        let (a, b) = Self.run(kernel, frames: frames)
        Self.expectClose(a, Self.train(frames: frames, start: Self.fade, gain: 0.5))
        Self.expectClose(b, Self.train(frames: frames, start: Self.fade, gain: 0.25))
    }

    @Test func turningOffFadesProgramBackIn() {
        let kernel = Kernel()
        domine_kernel_set_click_test(kernel.raw, 1)
        _ = Self.run(kernel, frames: Self.fade + 40, left: 0.3, right: -0.2)
        domine_kernel_set_click_test(kernel.raw, 0) // mid-click: the click stops at once
        let frames = Self.fade + 200
        let (a, b) = Self.run(kernel, frames: frames, left: 0.3, right: -0.2, chunk: 77)
        let level = (0..<frames).map { min(Float($0) / Float(Self.fade), 1) }
        Self.expectClose(a, level.map { $0 == 1 ? 0.3 : 0.3 * $0 })
        Self.expectClose(b, level.map { $0 == 1 ? -0.2 : -0.2 * $0 })
        #expect(a.suffix(200).allSatisfy { $0 == 0.3 })
        #expect(b.suffix(200).allSatisfy { $0 == -0.2 })
    }

    @Test func otherModesAreOff() {
        let kernel = Kernel()
        domine_kernel_set_click_test(kernel.raw, 3)
        let (a, b) = Self.run(kernel, frames: 600, left: 0.3, right: -0.2)
        #expect(a.allSatisfy { $0 == 0.3 })
        #expect(b.allSatisfy { $0 == -0.2 })
    }

    @Test func restartingBeginsWithAFreshClick() {
        let kernel = Kernel()
        domine_kernel_set_click_test(kernel.raw, 1)
        _ = Self.run(kernel, frames: Self.fade + 500)
        domine_kernel_set_click_test(kernel.raw, 0)
        _ = Self.run(kernel, frames: Self.fade)
        domine_kernel_set_click_test(kernel.raw, 1)
        let frames = Self.fade + 300
        let (a, b) = Self.run(kernel, frames: frames)
        Self.expectClose(a, Self.train(frames: frames, start: Self.fade))
        #expect(a == b)
    }
}
