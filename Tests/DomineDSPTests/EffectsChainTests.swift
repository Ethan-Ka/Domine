import DomineDSP
import Foundation
import Testing

/// Kernel effects chain (SPEC 5a): EQ, then bass, then compressor, per position.
/// Expected output comes from standalone module instances run one frame at a
/// time in the stated order, and must match the kernel bit for bit.
struct EffectsChainTests {
    static let sr = 48_000.0
    static let n = 512

    static func eqParams(gain: Float) -> DomineEQParams {
        var p = domine_eq_default_params()
        p.enabled = 1
        EQTests.setBand(&p, 1, 250, gain, 1)
        return p
    }

    static func bassParams(_ amount: Float) -> DomineBassParams {
        DomineBassParams(enabled: 1, amount: amount, cutoffHz: 120)
    }

    static func compParams(_ thr: Float) -> DomineCompressorParams {
        DomineCompressorParams(enabled: 1, thresholdDb: thr, ratio: 4, attackMs: 1, releaseMs: 50,
                               makeupDb: 3, limiterCeilingDb: -1)
    }

    static func input(_ hz: Double) -> [Float] {
        (0..<n).map { Float(0.6 * sin(2 * Double.pi * hz * Double($0) / sr)) }
    }

    enum Stage { case eq, bass, comp }

    /// Runs the stages in the given order on standalone instances, one frame per call.
    static func reference(_ x: [Float], _ order: [Stage], eq: DomineEQParams, bass: DomineBassParams,
                          comp: DomineCompressorParams) -> [Float] {
        let e = domine_eq_create(sr)!, b = domine_bass_create(sr)!, c = domine_compressor_create(sr)!
        defer { domine_eq_destroy(e); domine_bass_destroy(b); domine_compressor_destroy(c) }
        var ep = eq, bp = bass, cp = comp
        domine_eq_set_params(e, &ep)
        domine_bass_set_params(b, &bp)
        domine_compressor_set_params(c, &cp)
        var out = x
        for i in 0..<out.count {
            var s = out[i]
            for stage in order {
                switch stage {
                case .eq: domine_eq_process(e, &s, 1)
                case .bass: domine_bass_process(b, &s, 1)
                case .comp: domine_compressor_process(c, &s, 1)
                }
            }
            out[i] = s
        }
        return out
    }

    @Test func chainRunsEQThenBassThenCompressor() {
        let kernel = Kernel()
        var eq = Self.eqParams(gain: 9), bass = Self.bassParams(1), comp = Self.compParams(-20)
        domine_kernel_set_eq(kernel.raw, 0, &eq)
        domine_kernel_set_bass(kernel.raw, 0, &bass)
        domine_kernel_set_compressor(kernel.raw, 0, &comp)
        let x = Self.input(100)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.n)
        kernel.process(.interleaved(left: x, right: x), out)

        let expected = Self.reference(x, [.eq, .bass, .comp], eq: eq, bass: bass, comp: comp)
        let reversed = Self.reference(x, [.comp, .bass, .eq], eq: eq, bass: bass, comp: comp)
        #expect(bits(out.channel(0)) == bits(expected))
        #expect(bits(out.channel(1)) == bits(expected))
        #expect(bits(expected) != bits(reversed))
        // Position B untouched.
        #expect(bits(out.channel(2)) == bits(x))
    }

    @Test func positionsHaveIndependentChains() {
        let kernel = Kernel()
        var eqA = Self.eqParams(gain: 12), bassA = Self.bassParams(0.5), compA = Self.compParams(-24)
        var bassB = Self.bassParams(1), compB = Self.compParams(-10)
        var eqOff = domine_eq_default_params()
        domine_kernel_set_eq(kernel.raw, 0, &eqA)
        domine_kernel_set_bass(kernel.raw, 0, &bassA)
        domine_kernel_set_compressor(kernel.raw, 0, &compA)
        domine_kernel_set_eq(kernel.raw, 1, &eqOff)
        domine_kernel_set_bass(kernel.raw, 1, &bassB)
        domine_kernel_set_compressor(kernel.raw, 1, &compB)
        let l = Self.input(90), r = Self.input(200)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.n)
        kernel.process(.interleaved(left: l, right: r), out)

        let expA = Self.reference(l, [.eq, .bass, .comp], eq: eqA, bass: bassA, comp: compA)
        let expB = Self.reference(r, [.eq, .bass, .comp], eq: eqOff, bass: bassB, comp: compB)
        #expect(bits(out.channel(0)) == bits(expA))
        #expect(bits(out.channel(2)) == bits(expB))
        #expect(bits(out.channel(3)) == bits(expB))
    }

    @Test func onlyCompressorOnOneSide() {
        let kernel = Kernel()
        var comp = Self.compParams(-30)
        domine_kernel_set_compressor(kernel.raw, 1, &comp)
        let x = Self.input(440)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.n)
        kernel.process(.interleaved(left: x, right: x), out)
        let off = domine_eq_default_params()
        let bassOff = DomineBassParams(enabled: 0, amount: 0, cutoffHz: 120)
        let expected = Self.reference(x, [.comp], eq: off, bass: bassOff, comp: comp)
        #expect(bits(out.channel(0)) == bits(x))
        #expect(bits(out.channel(2)) == bits(expected))
    }

    @Test func allDisabledIsBitExact() {
        let kernel = Kernel()
        var eq = Self.eqParams(gain: 12)
        eq.enabled = 0
        var bass = DomineBassParams(enabled: 0, amount: 1, cutoffHz: 120)
        var comp = Self.compParams(-30)
        comp.enabled = 0
        for pos: Int32 in 0...1 {
            domine_kernel_set_eq(kernel.raw, pos, &eq)
            domine_kernel_set_bass(kernel.raw, pos, &bass)
            domine_kernel_set_compressor(kernel.raw, pos, &comp)
        }
        let l = ramp(Self.n), r = ramp(Self.n, start: 7)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.n)
        kernel.process(.interleaved(left: l, right: r), out)
        #expect(bits(out.channel(0)) == bits(l))
        #expect(bits(out.channel(2)) == bits(r))
    }

    @Test func bassIdleAfterFadeOut() {
        let b = domine_bass_create(Self.sr)!
        defer { domine_bass_destroy(b) }
        #expect(domine_bass_is_idle(b) != 0)
        var on = Self.bassParams(1)
        domine_bass_set_params(b, &on)
        #expect(domine_bass_is_idle(b) == 0)
        var x = Self.input(80)
        domine_bass_process(b, &x, UInt32(x.count))
        var off = DomineBassParams(enabled: 0, amount: 1, cutoffHz: 120)
        domine_bass_set_params(b, &off)
        #expect(domine_bass_is_idle(b) == 0)
        var silence = [Float](repeating: 0, count: 9600)
        domine_bass_process(b, &silence, UInt32(silence.count))
        #expect(domine_bass_is_idle(b) != 0)
    }
}
