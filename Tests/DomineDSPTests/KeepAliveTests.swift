import DomineDSP
import Testing

struct KeepAliveTests {
    static let rate = 48_000

    /// Runs `frames` frames of constant input in 512-frame calls; returns position A.
    static func run(_ kernel: Kernel, frames: Int, level: Float) -> [Float] {
        var a: [Float] = []
        var done = 0
        while done < frames {
            let n = min(512, frames - done)
            let input = TestBufferList.interleaved(
                left: Array(repeating: level, count: n), right: Array(repeating: level, count: n))
            let out = TestBufferList(channelsPerBuffer: [2, 2], frames: n)
            kernel.process(input, out)
            a += out.channel(0)
            done += n
        }
        return a
    }

    static func peak(_ x: ArraySlice<Float>) -> Float { x.map { abs($0) }.max() ?? 0 }

    @Test func offIsPassthrough() {
        let kernel = Kernel()
        let out = Self.run(kernel, frames: 3 * Self.rate, level: 0)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test func silenceGetsSignalAfterTwoSeconds() {
        let kernel = Kernel()
        domine_kernel_set_keep_alive(kernel.raw, 1)
        let out = Self.run(kernel, frames: 3 * Self.rate, level: 0)
        #expect(Self.peak(out[0..<(2 * Self.rate)]) == 0)
        let tail = Self.peak(out[(2 * Self.rate + 4_800)...])
        #expect(abs(tail - 0.001) < 0.00002)
    }

    @Test func loudInputGetsNothingAdded() {
        let kernel = Kernel()
        domine_kernel_set_keep_alive(kernel.raw, 1)
        let out = Self.run(kernel, frames: 3 * Self.rate, level: 0.25)
        #expect(out.allSatisfy { $0 == 0.25 })
    }
}
