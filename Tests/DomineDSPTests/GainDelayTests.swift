import DomineDSP
import Testing

struct GainTests {
    static let left: [Float] = [0.5, -0.5, 1.0, 0.25]
    static let right: [Float] = [0.8, -0.4, 0.2, -1.0]

    @Test func perPositionGain() {
        let kernel = Kernel()
        domine_kernel_set_gains(kernel.raw, 0.5, 0.25)
        let out = TestBufferList(channelsPerBuffer: [4], frames: 4)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out)
        #expect(out.channel(0) == Self.left.map { $0 * 0.5 })
        #expect(out.channel(1) == Self.left.map { $0 * 0.5 })
        #expect(out.channel(2) == Self.right.map { $0 * 0.25 })
        #expect(out.channel(3) == Self.right.map { $0 * 0.25 })
    }

    @Test func gainFollowsPositionAfterSwap() {
        let kernel = Kernel()
        domine_kernel_set_gains(kernel.raw, 0.5, 0.25)
        domine_kernel_set_mode(kernel.raw, 1, 1, 0)
        let out = TestBufferList(channelsPerBuffer: [4], frames: 4)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out)
        #expect(out.channel(0) == Self.right.map { $0 * 0.5 })
        #expect(out.channel(2) == Self.left.map { $0 * 0.25 })
    }

    @Test func invalidGainsBecomeZero() {
        let kernel = Kernel()
        domine_kernel_set_gains(kernel.raw, .nan, -1)
        let out = TestBufferList(channelsPerBuffer: [4], frames: 4)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out)
        for channel in 0..<4 { #expect(out.channel(channel) == zeros(4)) }
    }
}

struct DelayTests {
    /// Feeds `left`/`right` through the kernel in chunks and returns the
    /// concatenated A and B outputs.
    static func run(_ kernel: Kernel, left: [Float], right: [Float], chunk: Int) -> (a: [Float], b: [Float]) {
        var a: [Float] = []
        var b: [Float] = []
        var start = 0
        while start < left.count {
            let end = min(start + chunk, left.count)
            let input = TestBufferList.interleaved(left: Array(left[start..<end]), right: Array(right[start..<end]))
            let out = TestBufferList(channelsPerBuffer: [2, 2], frames: end - start)
            kernel.process(input, out)
            a += out.channel(0)
            b += out.channel(2)
            #expect(out.channel(1) == out.channel(0))
            #expect(out.channel(3) == out.channel(2))
            start = end
        }
        return (a, b)
    }

    static func delayed(_ x: [Float], by d: Int) -> [Float] {
        zeros(min(d, x.count)) + x.prefix(max(0, x.count - d))
    }

    @Test func positiveDelayShiftsB() {
        let kernel = Kernel(sampleRate: 48_000)
        domine_kernel_set_delay_ms(kernel.raw, 1) // 48 samples
        let left = ramp(200)
        let right = ramp(200, scale: -0.002)
        let (a, b) = Self.run(kernel, left: left, right: right, chunk: 32)
        #expect(a == left)
        #expect(b == Self.delayed(right, by: 48))
    }

    @Test func negativeDelayShiftsA() {
        let kernel = Kernel(sampleRate: 48_000)
        domine_kernel_set_delay_ms(kernel.raw, -2) // 96 samples
        let left = ramp(300)
        let right = ramp(300, scale: -0.002)
        let (a, b) = Self.run(kernel, left: left, right: right, chunk: 50)
        #expect(a == Self.delayed(left, by: 96))
        #expect(b == right)
    }

    @Test func delayRoundsToNearestSample() {
        let kernel = Kernel(sampleRate: 44_100)
        domine_kernel_set_delay_ms(kernel.raw, 0.5) // 22.05 -> 22
        let left = ramp(64)
        let right = ramp(64, scale: -0.002)
        let (_, b) = Self.run(kernel, left: left, right: right, chunk: 64)
        #expect(b == Self.delayed(right, by: 22))
    }

    @Test func delayAppliesToPositionAfterSwap() {
        let kernel = Kernel(sampleRate: 48_000)
        domine_kernel_set_mode(kernel.raw, 1, 1, 0)
        domine_kernel_set_delay_ms(kernel.raw, 1)
        let left = ramp(100)
        let right = ramp(100, scale: -0.002)
        let (a, b) = Self.run(kernel, left: left, right: right, chunk: 40)
        #expect(a == right)
        #expect(b == Self.delayed(left, by: 48))
    }

    @Test(arguments: [(Float(1000), 14_400), (Float(-1000), -14_400), (Float(300), 14_400)])
    func delayClampsTo300ms(ms: Float, expectedSamples: Int) {
        let kernel = Kernel(sampleRate: 48_000, maxFrames: 512)
        domine_kernel_set_delay_ms(kernel.raw, ms)
        let count = 15_000
        var impulse = zeros(count)
        impulse[0] = 1
        let (a, b) = Self.run(kernel, left: impulse, right: impulse, chunk: 512)
        let delayedSide = expectedSamples > 0 ? b : a
        let direct = expectedSamples > 0 ? a : b
        #expect(delayedSide.firstIndex(of: 1) == abs(expectedSamples))
        #expect(delayedSide.filter { $0 != 0 }.count == 1)
        #expect(direct.firstIndex(of: 1) == 0)
    }

    @Test func fullDelayAt96kReadsOnlyZeroedHistory() {
        let kernel = Kernel(sampleRate: 96_000)
        domine_kernel_set_delay_ms(kernel.raw, 300) // 28,800 samples
        let ones = Array(repeating: Float(1), count: 30_000)
        let (_, b) = Self.run(kernel, left: ones, right: ones, chunk: 4096)
        #expect(b.prefix(28_800).allSatisfy { $0 == 0 })
        #expect(b.dropFirst(28_800).allSatisfy { $0 == 1 })
    }

    @Test func changingDelayMidStreamReadsHistory() {
        let kernel = Kernel(sampleRate: 48_000)
        let right = ramp(200, scale: -0.002)
        let left = ramp(200)
        _ = Self.run(kernel, left: Array(left[0..<100]), right: Array(right[0..<100]), chunk: 100)
        domine_kernel_set_delay_ms(kernel.raw, 1)
        let (_, b) = Self.run(kernel, left: Array(left[100...]), right: Array(right[100...]), chunk: 100)
        #expect(b == Array(right[52..<152]))
    }
}

/// Trim gain changes ramp over 30 ms (30 samples at 1 kHz).
struct GainRampTests {
    static let ones = [Float](repeating: 1, count: 40)

    private func run(_ kernel: Kernel, frames: Int = 40) -> TestBufferList {
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: frames)
        kernel.process(.interleaved(left: [Float](repeating: 1, count: frames),
                                    right: [Float](repeating: 1, count: frames)), out)
        return out
    }

    @Test func changeRampsLinearlyAndLandsExactly() {
        let kernel = Kernel(sampleRate: 1000)
        _ = run(kernel, frames: 4)
        domine_kernel_set_gains(kernel.raw, 0.4, 0.7)
        let out = run(kernel)
        let a = out.channel(0)
        let b = out.channel(2)
        for i in 0..<29 {
            let t = Float(i + 1) / 30
            #expect(abs(a[i] - (1 + (0.4 - 1) * t)) < 1e-5)
            #expect(abs(b[i] - (1 + (0.7 - 1) * t)) < 1e-5)
        }
        #expect(a[29] == 0.4 && b[29] == 0.7)
        #expect(Array(a[30...]) == [Float](repeating: 0.4, count: 10))
        #expect(out.channel(1) == a)
    }

    @Test func unchangedGainDoesNotRamp() {
        let kernel = Kernel(sampleRate: 1000)
        domine_kernel_set_gains(kernel.raw, 0.5, 0.5)
        _ = run(kernel, frames: 4)
        domine_kernel_set_gains(kernel.raw, 0.5, 0.5)
        let out = run(kernel)
        #expect(out.channel(0) == [Float](repeating: 0.5, count: 40))
    }

    @Test func rampBackToUnityIsBitExact() {
        let kernel = Kernel(sampleRate: 1000)
        domine_kernel_set_gains(kernel.raw, 0.5, 0.5)
        _ = run(kernel, frames: 4)
        domine_kernel_set_gains(kernel.raw, 1, 1)
        let out = run(kernel)
        #expect(out.channel(0)[29] == 1)
        #expect(Array(out.channel(0)[30...]) == [Float](repeating: 1, count: 10))
    }
}
