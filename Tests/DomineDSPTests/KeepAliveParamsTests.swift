import DomineDSP
import Foundation
import Testing

/// Keep-alive idle time, frequency and level (Settings > Advanced).
struct KeepAliveParamsTests {
    static let rate = 48_000.0

    /// The tone the kernels add to silent input, computed with the same
    /// operations in the same order, so the match is exact.
    static func expected(frames: Int, hold: Double, hz: Double, amplitude: Double) -> [Float] {
        let holdFrames = UInt32(lround(rate * hold))
        let step = Float(1.0 / (rate * 0.05))
        var level: Float = 0, phase = 0.0, silent: UInt32 = 0
        var out: [Float] = []
        for _ in 0..<frames {
            silent += 1
            if silent > holdFrames { level = min(level + step, 1) }
            out.append(level > 0 ? Float(amplitude * sin(2.0 * Double.pi * phase)) * level : 0)
            phase += hz / rate
            if phase >= 1 { phase -= 1 }
        }
        return out
    }

    static func runStereo(params: (Double, Double, Double)?, frames: Int) -> [Float] {
        let kernel = Kernel()
        domine_kernel_set_keep_alive(kernel.raw, 1)
        if let (hold, hz, amp) = params { domine_kernel_set_keep_alive_params(kernel.raw, hold, hz, amp) }
        return KeepAliveTests.run(kernel, frames: frames, level: 0)
    }

    static func runSurround(params: (Double, Double, Double)?, frames: Int) -> [Float] {
        let s = SurroundKernelTests.make([-30, 30])
        defer { domine_surround_destroy(s) }
        domine_surround_set_keep_alive(s, 1)
        if let (hold, hz, amp) = params { domine_surround_set_keep_alive_params(s, hold, hz, amp) }
        return SurroundKeepAliveTests.run(s, frames: frames, level: 0)
    }

    @Test func defaultParamsAreBitExactWithNoCall() {
        let frames = Int(2.5 * Self.rate)
        #expect(Self.runStereo(params: (2, 15, 1.0e-3), frames: frames) == Self.runStereo(params: nil, frames: frames))
        #expect(Self.runSurround(params: (2, 15, 1.0e-3), frames: frames)
            == Self.runSurround(params: nil, frames: frames))
    }

    @Test func defaultToneMatchesFormula() {
        let frames = Int(2.2 * Self.rate)
        #expect(Self.runStereo(params: nil, frames: frames)
            == Self.expected(frames: frames, hold: 2, hz: 15, amplitude: 1.0e-3))
    }

    @Test func customHoldFrequencyAndLevelExact() {
        let frames = Int(0.8 * Self.rate)
        let out = Self.runStereo(params: (0.5, 40, 0.01), frames: frames)
        #expect(out == Self.expected(frames: frames, hold: 0.5, hz: 40, amplitude: 0.01))
        #expect(out[0..<24_000].allSatisfy { $0 == 0 })
        #expect(out[24_000] != 0)
    }

    @Test func surroundCustomParamsStartAtTheNewHold() {
        let frames = Int(0.8 * Self.rate)
        let out = Self.runSurround(params: (0.5, 40, 0.01), frames: frames)
        #expect(out[0..<24_000].allSatisfy { $0 == 0 })
        let tail = KeepAliveTests.peak(out[(24_000 + 4_800)...])
        #expect(abs(tail - 0.01) < 0.0002)
    }

    @Test func outOfRangeValuesClamp() {
        let frames = Int(0.8 * Self.rate)
        // 0.1 s, 100 Hz and 1.0 clamp to 0.5 s, 40 Hz and -40 dBFS.
        #expect(Self.runStereo(params: (0.1, 100, 1.0), frames: frames)
            == Self.runStereo(params: (0.5, 40, 0.01), frames: frames))
        // Non-finite values take the defaults.
        let long = Int(2.2 * Self.rate)
        #expect(Self.runStereo(params: (.nan, .infinity, .nan), frames: long)
            == Self.runStereo(params: nil, frames: long))
    }
}
