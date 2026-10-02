import DomineDSP
import Testing

/// At unity gain, zero delay, no swap, no tone, no click, and no mute the
/// kernel copies program audio bit for bit (SPEC section 4, Signal quality).
/// Every comparison here is on bit patterns, not values.
struct TransparencyTests {
    /// 50 ms mute fade, 40 ms tone and click fades at 48 kHz, plus margin.
    static let settleFrames = 2_400 + 1_920 + 512

    /// Deterministic samples covering the awkward cases: signed zeros,
    /// subnormals, the smallest normals, values just under and above full
    /// scale, and a spread of exponents.
    static func signal(_ count: Int, seed: UInt64) -> [Float] {
        let specials: [Float] = [
            0, -0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
            .leastNormalMagnitude, -.leastNormalMagnitude, 1, -1,
            Float(1).nextDown, -(Float(1).nextDown), 1.5, -2, 1e-30, 0.1, 1.0 / 3.0,
        ]
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return (0..<count).map { i in
            if i < specials.count { return specials[i] }
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            // Random sign and mantissa, exponent from 2^-40 to 2^0.
            let sign = UInt32(state & 1) << 31
            let exponent = UInt32(87 + (state >> 1) % 41) << 23
            let mantissa = UInt32(truncatingIfNeeded: state >> 20) & 0x7F_FFFF
            return Float(bitPattern: sign | exponent | mantissa)
        }
    }

    static func bits(_ x: [Float]) -> [UInt32] { x.map(\.bitPattern) }

    /// Runs `frames` frames through `process` in 512-frame calls and returns
    /// positions A (channel 0) and B (channel 2), checking that each
    /// position's second channel matches its first bit for bit.
    @discardableResult
    static func run(_ kernel: Kernel, left: [Float], right: [Float],
                    sourceLocation: SourceLocation = #_sourceLocation) -> (a: [Float], b: [Float]) {
        var a: [Float] = [], b: [Float] = []
        var start = 0
        while start < left.count {
            let end = min(start + 512, left.count)
            let input = TestBufferList.interleaved(left: Array(left[start..<end]), right: Array(right[start..<end]))
            let out = TestBufferList(channelsPerBuffer: [2, 2], frames: end - start)
            kernel.process(input, out)
            #expect(bits(out.channel(1)) == bits(out.channel(0)), sourceLocation: sourceLocation)
            #expect(bits(out.channel(3)) == bits(out.channel(2)), sourceLocation: sourceLocation)
            a += out.channel(0)
            b += out.channel(2)
            start = end
        }
        return (a, b)
    }

    /// Feeds a fresh block and expects it back exactly on both positions.
    static func expectTransparent(_ kernel: Kernel, seed: UInt64, frames: Int = 4_096,
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        let left = signal(frames, seed: seed)
        let right = signal(frames, seed: seed &+ 1)
        let (a, b) = run(kernel, left: left, right: right, sourceLocation: sourceLocation)
        #expect(bits(a) == bits(left), sourceLocation: sourceLocation)
        #expect(bits(b) == bits(right), sourceLocation: sourceLocation)
    }

    /// Plays program audio for `frames` frames, to let fades run.
    static func settle(_ kernel: Kernel, frames: Int = settleFrames, seed: UInt64 = 99) {
        run(kernel, left: signal(frames, seed: seed), right: signal(frames, seed: seed &+ 7))
    }

    // MARK: - Fresh kernel

    @Test func freshKernelIsBitExactOnBothPositions() {
        Self.expectTransparent(Kernel(), seed: 1)
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func bitExactAtEveryRate(sampleRate: Double) {
        Self.expectTransparent(Kernel(sampleRate: sampleRate), seed: 2)
    }

    @Test func deinterleavedInputAndMonoOutputStreamsAreBitExact() {
        let kernel = Kernel()
        let left = Self.signal(1_024, seed: 3), right = Self.signal(1_024, seed: 4)
        let out = TestBufferList(channelsPerBuffer: [1, 1, 1, 1], frames: 1_024)
        kernel.process(.deinterleaved(left: left, right: right), out)
        for channel in 0..<2 { #expect(Self.bits(out.channel(channel)) == Self.bits(left)) }
        for channel in 2..<4 { #expect(Self.bits(out.channel(channel)) == Self.bits(right)) }
    }

    @Test func ioprocIsBitExactAcrossCycles() {
        let kernel = Kernel()
        for cycle in 0..<8 {
            let left = Self.signal(512, seed: UInt64(10 + cycle)), right = Self.signal(512, seed: UInt64(50 + cycle))
            let out = TestBufferList(channelsPerBuffer: [2, 2], frames: 512)
            kernel.ioproc(.interleaved(left: left, right: right), out)
            #expect(Self.bits(out.channel(0)) == Self.bits(left))
            #expect(Self.bits(out.channel(1)) == Self.bits(left))
            #expect(Self.bits(out.channel(2)) == Self.bits(right))
            #expect(Self.bits(out.channel(3)) == Self.bits(right))
        }
    }

    @Test func aboveFullScaleInputPassesUnclipped() {
        let kernel = Kernel()
        let left: [Float] = [1.5, -3, Float(1).nextUp, 100]
        let right: [Float] = [-1.5, 2, -(Float(1).nextUp), -100]
        let (a, b) = Self.run(kernel, left: left, right: right)
        #expect(Self.bits(a) == Self.bits(left))
        #expect(Self.bits(b) == Self.bits(right))
    }

    // MARK: - After every control returns to neutral

    @Test(arguments: [Float(50), -50, 0.4, -300])
    func bitExactAfterDelayReturnsToZero(ms: Float) {
        let kernel = Kernel()
        domine_kernel_set_delay_ms(kernel.raw, ms)
        Self.settle(kernel)
        domine_kernel_set_delay_ms(kernel.raw, 0)
        Self.expectTransparent(kernel, seed: 5)
    }

    @Test func bitExactAfterMuteAndUnmuteFadesComplete() {
        let kernel = Kernel()
        domine_kernel_set_muted(kernel.raw, 1)
        Self.settle(kernel)
        domine_kernel_set_muted(kernel.raw, 0)
        Self.settle(kernel)
        Self.expectTransparent(kernel, seed: 6)
    }

    @Test func bitExactAfterAnInterruptedMuteFade() {
        let kernel = Kernel()
        domine_kernel_set_muted(kernel.raw, 1)
        Self.settle(kernel, frames: 700)
        domine_kernel_set_muted(kernel.raw, 0)
        Self.settle(kernel)
        Self.expectTransparent(kernel, seed: 7)
    }

    @Test(arguments: [Int32(1), 2])
    func bitExactAfterTheToneFadesOut(side: Int32) {
        let kernel = Kernel()
        domine_kernel_set_test_tone(kernel.raw, side)
        Self.settle(kernel)
        domine_kernel_set_test_tone(kernel.raw, 0)
        Self.settle(kernel)
        Self.expectTransparent(kernel, seed: 8)
    }

    @Test func bitExactAfterTheToneMovesAndStops() {
        let kernel = Kernel()
        domine_kernel_set_test_tone(kernel.raw, 1)
        Self.settle(kernel, frames: 1_000)
        domine_kernel_set_test_tone(kernel.raw, 2)
        Self.settle(kernel, frames: 1_000)
        domine_kernel_set_test_tone(kernel.raw, 0)
        Self.settle(kernel)
        Self.expectTransparent(kernel, seed: 9)
    }

    @Test func bitExactAfterTheClickTestStops() {
        let kernel = Kernel()
        domine_kernel_set_click_test(kernel.raw, 1)
        Self.settle(kernel)
        domine_kernel_set_click_test(kernel.raw, 0)
        Self.settle(kernel)
        Self.expectTransparent(kernel, seed: 10)
    }

    @Test func bitExactAfterSwapTurnsOff() {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 1, 1, 0)
        Self.settle(kernel)
        domine_kernel_set_mode(kernel.raw, 1, 0, 0)
        Self.expectTransparent(kernel, seed: 11)
    }

    @Test func bitExactAfterGainReturnsToUnity() {
        let kernel = Kernel()
        domine_kernel_set_gains(kernel.raw, 0.5, 0.3)
        Self.settle(kernel)
        domine_kernel_set_gains(kernel.raw, 1, 1)
        Self.expectTransparent(kernel, seed: 12)
    }

    @Test func everythingAtOnceThenNeutral() {
        let kernel = Kernel()
        domine_kernel_set_delay_ms(kernel.raw, -20)
        domine_kernel_set_gains(kernel.raw, 0.7, 0.2)
        domine_kernel_set_mode(kernel.raw, 1, 1, 0)
        domine_kernel_set_muted(kernel.raw, 1)
        domine_kernel_set_click_test(kernel.raw, 1)
        domine_kernel_set_test_tone(kernel.raw, 2)
        Self.settle(kernel)
        domine_kernel_set_delay_ms(kernel.raw, 0)
        domine_kernel_set_gains(kernel.raw, 1, 1)
        domine_kernel_set_mode(kernel.raw, 1, 0, 0)
        domine_kernel_set_muted(kernel.raw, 0)
        domine_kernel_set_click_test(kernel.raw, 0)
        domine_kernel_set_test_tone(kernel.raw, 0)
        Self.settle(kernel)
        Self.expectTransparent(kernel, seed: 13)
    }

    // MARK: - Exact transforms

    @Test func swapIsAnExactExchange() {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 1, 1, 0)
        let left = Self.signal(1_024, seed: 14), right = Self.signal(1_024, seed: 15)
        let (a, b) = Self.run(kernel, left: left, right: right)
        #expect(Self.bits(a) == Self.bits(right))
        #expect(Self.bits(b) == Self.bits(left))
    }

    @Test func delayIsAnExactShift() {
        let kernel = Kernel()
        domine_kernel_set_delay_ms(kernel.raw, 10) // 480 samples on B
        let left = Self.signal(2_048, seed: 16), right = Self.signal(2_048, seed: 17)
        let (a, b) = Self.run(kernel, left: left, right: right)
        #expect(Self.bits(a) == Self.bits(left))
        #expect(Self.bits(b) == Self.bits(zeros(480) + right.prefix(2_048 - 480)))
    }

    @Test func monoFallbackIsTheOnlyMix() {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 1, 0, 1)
        let left = Self.signal(1_024, seed: 18), right = Self.signal(1_024, seed: 19)
        let (a, b) = Self.run(kernel, left: left, right: right)
        let mixed = zip(left, right).map { ($0 + $1) * 0.5 }
        #expect(Self.bits(a) == Self.bits(mixed))
        #expect(Self.bits(b) == Self.bits(mixed))
    }

    // MARK: - Headroom

    @Test func gainsAboveOneAreHeldAtUnity() {
        let kernel = Kernel()
        domine_kernel_set_gains(kernel.raw, 2, 1_000)
        Self.expectTransparent(kernel, seed: 20)
    }

    @Test func gainJustAboveOneIsUnity() {
        let kernel = Kernel()
        domine_kernel_set_gains(kernel.raw, Float(1).nextUp, Float(1).nextUp)
        Self.expectTransparent(kernel, seed: 21)
    }

    /// Full-scale program with every test signal and fade toggled on and off
    /// at awkward moments: no output sample ever leaves [-1, 1].
    @Test func testSignalsAndFadesStayWithinFullScale() {
        let kernel = Kernel()
        var outputs: [Float] = []
        let fullScale = (0..<512).map { $0 % 2 == 0 ? Float(1) : -1 }
        let steps: [(OpaquePointer) -> Void] = [
            { domine_kernel_set_click_test($0, 1) },
            { domine_kernel_set_test_tone($0, 1) },
            { domine_kernel_set_muted($0, 1) },
            { domine_kernel_set_click_test($0, 0) },
            { domine_kernel_set_muted($0, 0) },
            { domine_kernel_set_test_tone($0, 2) },
            { domine_kernel_set_delay_ms($0, 3) },
            { domine_kernel_set_test_tone($0, 0) },
            { domine_kernel_set_click_test($0, 1) },
            { domine_kernel_set_mode($0, 1, 1, 0) },
            { domine_kernel_set_click_test($0, 0) },
        ]
        for step in steps {
            step(kernel.raw)
            for _ in 0..<3 {
                let (a, b) = Self.run(kernel, left: fullScale, right: fullScale.map { -$0 })
                outputs += a + b
            }
        }
        #expect(outputs.allSatisfy { abs($0) <= 1 })
        #expect(outputs.contains { abs($0) == 1 })
    }
}
