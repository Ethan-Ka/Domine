import DomineDSP
import Testing

/// Volume boost above 100% (SPEC 4a): gain, then a linked peak limiter.
struct BoostTests {
    static let ceiling: Float = 0.8912509
    static let left: [Float] = [0.1, -0.2, 0.3, 0.05]
    static let right: [Float] = [0.2, 0.1, -0.15, 0.4]

    @Test func quietAudioIsMultipliedExactly() {
        let kernel = Kernel()
        domine_kernel_set_boost(kernel.raw, 2)
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: 4)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out)
        #expect(out.channel(0) == Self.left.map { $0 * 2 })
        #expect(out.channel(1) == Self.left.map { $0 * 2 })
        #expect(out.channel(2) == Self.right.map { $0 * 2 })
    }

    @Test func loudAudioStaysUnderTheCeiling() {
        let kernel = Kernel()
        domine_kernel_set_boost(kernel.raw, DOMINE_MAX_BOOST)
        let frames = 512
        let loud = (0..<frames).map { $0 % 2 == 0 ? Float(0.9) : Float(-0.7) }
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: frames)
        kernel.process(.interleaved(left: loud, right: loud.map { $0 * 0.5 }), out)
        #expect(out.channel(0).allSatisfy { abs($0) <= Self.ceiling })
        #expect(out.channel(2).allSatisfy { abs($0) <= Self.ceiling })
        // The first sample hits the ceiling at once (instant attack).
        #expect(out.channel(0)[0] == Self.ceiling)
        // Linked: B keeps its ratio to A.
        #expect(out.channel(2)[0] == 0.45 * DOMINE_MAX_BOOST * (Self.ceiling / (0.9 * DOMINE_MAX_BOOST)))
    }

    @Test func belowOneAndInvalidAreUnity() {
        for value: Float in [0.5, .nan, 1] {
            let kernel = Kernel()
            domine_kernel_set_boost(kernel.raw, value)
            let out = TestBufferList(channelsPerBuffer: [2, 2], frames: 4)
            kernel.process(.interleaved(left: Self.left, right: Self.right), out)
            #expect(out.channel(0) == Self.left)
            #expect(out.channel(2) == Self.right)
        }
    }

    @Test func clampsToTheMaximum() {
        let kernel = Kernel()
        domine_kernel_set_boost(kernel.raw, 100)
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: 1)
        kernel.process(.interleaved(left: [0.1], right: [0.1]), out)
        #expect(out.channel(0) == [0.1 * DOMINE_MAX_BOOST])
    }

    @Test func returningToOneIsBitExactOnceReleased() {
        let kernel = Kernel(sampleRate: 48_000)
        domine_kernel_set_boost(kernel.raw, 2)
        let warm = TestBufferList(channelsPerBuffer: [2, 2], frames: 64)
        kernel.process(.interleaved(left: Array(repeating: 0.1, count: 64), right: Array(repeating: 0.1, count: 64)), warm)
        domine_kernel_set_boost(kernel.raw, 1)
        // 30 ms ramp at 48 kHz is 1440 samples.
        let ramp = TestBufferList(channelsPerBuffer: [2, 2], frames: 2000)
        kernel.process(.interleaved(left: Array(repeating: 0.1, count: 2000), right: Array(repeating: 0.1, count: 2000)), ramp)
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: 4)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(2) == Self.right)
    }
}
