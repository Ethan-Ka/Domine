import DomineDSP
import Testing

struct CrossfeedTests {
    static let left: [Float] = [0.5, 0.25, -0.5, 1.0, 0.125, -0.25, 0.75, 0.0]
    static let right: [Float] = [-0.25, 0.5, 0.25, 0.0, -0.125, 0.75, -0.5, 1.0]
    static let frames = left.count

    func run(amount: Float, swap: Int32 = 0, fallback: Int32 = 0) -> TestBufferList {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 1, swap, fallback)
        domine_kernel_set_crossfeed(kernel.raw, amount)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.frames)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out)
        return out
    }

    func expect(_ out: TestBufferList, a: [Float], b: [Float]) {
        #expect(out.channel(0) == a)
        #expect(out.channel(1) == a)
        #expect(out.channel(2) == b)
        #expect(out.channel(3) == b)
    }

    @Test func zeroIsUntouched() {
        expect(run(amount: 0), a: Self.left, b: Self.right)
    }

    @Test func halfBlendsThreeQuartersToOneQuarter() {
        let a = zip(Self.left, Self.right).map { 0.75 * $0 + 0.25 * $1 }
        let b = zip(Self.right, Self.left).map { 0.75 * $0 + 0.25 * $1 }
        expect(run(amount: 0.5), a: a, b: b)
    }

    @Test func fullGivesBothSpeakersTheMidSignal() {
        let mid = zip(Self.left, Self.right).map { ($0 + $1) * 0.5 }
        expect(run(amount: 1), a: mid, b: mid)
    }

    @Test func swapMapsBeforeCrossfeed() {
        let a = zip(Self.right, Self.left).map { 0.75 * $0 + 0.25 * $1 }
        let b = zip(Self.left, Self.right).map { 0.75 * $0 + 0.25 * $1 }
        expect(run(amount: 0.5, swap: 1), a: a, b: b)
    }

    @Test func swapAtZeroIsPlainSwap() {
        expect(run(amount: 0, swap: 1), a: Self.right, b: Self.left)
    }

    @Test func monoFallbackIgnoresCrossfeed() {
        let mid = zip(Self.left, Self.right).map { ($0 + $1) * 0.5 }
        expect(run(amount: 0.5, fallback: 1), a: mid, b: mid)
    }

    @Test func outOfRangeAndNonFiniteAreClamped() {
        let mid = zip(Self.left, Self.right).map { ($0 + $1) * 0.5 }
        expect(run(amount: 7), a: mid, b: mid)
        expect(run(amount: -1), a: Self.left, b: Self.right)
        expect(run(amount: .nan), a: Self.left, b: Self.right)
    }
}
