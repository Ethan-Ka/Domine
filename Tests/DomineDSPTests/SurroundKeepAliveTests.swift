import DomineDSP
import Testing

struct SurroundKeepAliveTests {
    static let rate = 48_000

    /// Runs `frames` frames of constant input in 512-frame calls; returns output channel 0.
    static func run(_ s: OpaquePointer, frames: Int, level: Float) -> [Float] {
        var a: [Float] = []
        var done = 0
        let offsets: [UInt32] = [0, 2]
        while done < frames {
            let n = min(512, frames - done)
            let input = TestBufferList.interleaved(
                left: Array(repeating: level, count: n), right: Array(repeating: level, count: n))
            let out = TestBufferList(channelsPerBuffer: [4], frames: n)
            offsets.withUnsafeBufferPointer {
                domine_surround_process(s, input.pointer, out.pointer, UInt32(n), $0.baseAddress!)
            }
            a += out.channel(0)
            done += n
        }
        return a
    }

    static func peak(_ x: ArraySlice<Float>) -> Float { x.map { abs($0) }.max() ?? 0 }

    @Test func offIsSilent() {
        let s = SurroundKernelTests.make([-30, 30])
        let out = Self.run(s, frames: 3 * Self.rate, level: 0)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test func silenceGetsSignalAfterTwoSeconds() {
        let s = SurroundKernelTests.make([-30, 30])
        domine_surround_set_keep_alive(s, 1)
        let out = Self.run(s, frames: 3 * Self.rate, level: 0)
        #expect(Self.peak(out[0..<(2 * Self.rate)]) == 0)
        let tail = Self.peak(out[(2 * Self.rate + 4_800)...])
        #expect(abs(tail - 0.001) < 0.00002)
    }

    @Test func loudInputGetsNothingAdded() {
        let s = SurroundKernelTests.make([-30, 30])
        domine_surround_set_keep_alive(s, 1)
        let reference = SurroundKernelTests.make([-30, 30])
        let a = Self.run(s, frames: 3 * Self.rate, level: 0.25)
        let b = Self.run(reference, frames: 3 * Self.rate, level: 0.25)
        #expect(a == b)
    }
}
