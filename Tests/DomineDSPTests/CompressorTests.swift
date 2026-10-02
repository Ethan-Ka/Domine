import Foundation
import Testing
import DomineDSP

struct CompressorTests {
    static let sr = 48_000.0

    static func params(enabled: Bool = true, thr: Float = -18, ratio: Float = 4,
                       attack: Float = 10, release: Float = 100,
                       makeup: Float = 0, ceiling: Float = 0) -> DomineCompressorParams {
        DomineCompressorParams(enabled: enabled ? 1 : 0, thresholdDb: thr, ratio: ratio,
                               attackMs: attack, releaseMs: release,
                               makeupDb: makeup, limiterCeilingDb: ceiling)
    }

    static func make(_ p: DomineCompressorParams) -> OpaquePointer {
        let c = domine_compressor_create(sr)!
        var q = p
        domine_compressor_set_params(c, &q)
        return c
    }

    static func lin(_ db: Double) -> Float { Float(pow(10, db / 20)) }

    @Test func disabledIsBitExact() {
        let c = Self.make(Self.params(enabled: false, makeup: 12))
        defer { domine_compressor_destroy(c) }
        var x = (0..<4096).map { Float(sin(Double($0) * 0.37)) * 3 + Float($0 % 7) * 0.1 }
        let ref = x
        domine_compressor_process(c, &x, UInt32(x.count))
        #expect(zip(x, ref).allSatisfy { $0.bitPattern == $1.bitPattern })
    }

    @Test func staticCurve() {
        // thr -18, ratio 4, knee 6: (input dB, expected gain dB)
        let cases: [(Double, Double)] = [(-40, 0), (-24, 0), (-18, -0.5625), (-12, -4.5), (-10, -6), (-6, -9)]
        for (level, gain) in cases {
            let c = Self.make(Self.params())
            var x = [Float](repeating: Self.lin(level), count: 96_000)
            domine_compressor_process(c, &x, UInt32(x.count))
            let out = 20 * log10(Double(x.last!)) - level
            #expect(abs(out - gain) < 0.1, "level \(level): got \(out) want \(gain)")
            domine_compressor_destroy(c)
        }
    }

    @Test func attackAndReleaseTimeConstants() {
        let c = Self.make(Self.params())
        defer { domine_compressor_destroy(c) }
        // Attack: input at -6 dB, steady gain -9 dB. After one attack time, 63.2% of it.
        var loud = [Float](repeating: Self.lin(-6), count: 480)
        domine_compressor_process(c, &loud, 480)
        let attackGain = 20 * log10(Double(loud[479])) + 6
        #expect(abs(attackGain - (-9 * (1 - exp(-1.0)))) < 0.1)

        // Settle, then drop to -40 dB (target gain 0). After one release time, 36.8% of -9 dB remains.
        var settle = [Float](repeating: Self.lin(-6), count: 48_000)
        domine_compressor_process(c, &settle, UInt32(settle.count))
        var quiet = [Float](repeating: Self.lin(-40), count: 4800)
        domine_compressor_process(c, &quiet, 4800)
        let releaseGain = 20 * log10(Double(quiet[4799])) + 40
        #expect(abs(releaseGain - (-9 * exp(-1.0))) < 0.1)
    }

    @Test func neverExceedsCeiling() {
        let ceiling: Float = -1
        let limit = Self.lin(Double(ceiling))
        let c = Self.make(Self.params(thr: -30, ratio: 2, attack: 0.1, makeup: 12, ceiling: ceiling))
        defer { domine_compressor_destroy(c) }
        var sine = (0..<48_000).map { Float(sin(2 * Double.pi * 1000 * Double($0) / Self.sr)) }
        domine_compressor_process(c, &sine, UInt32(sine.count))
        #expect(sine.allSatisfy { abs($0) <= limit })
        #expect(sine.map { abs($0) }.max()! > limit * 0.9)

        var imp = [Float](repeating: 0, count: 48_000)
        for i in stride(from: 100, to: imp.count, by: 997) { imp[i] = i % 2 == 0 ? 1 : -1 }
        domine_compressor_process(c, &imp, UInt32(imp.count))
        #expect(imp.allSatisfy { abs($0) <= limit })
    }

    @Test func parameterSwapIsGlitchFree() {
        let a = Self.params(thr: -12, ratio: 2, attack: 5, release: 50, makeup: 0)
        let b = Self.params(thr: -30, ratio: 8, attack: 5, release: 50, makeup: 6)
        let c = Self.make(a)
        defer { domine_compressor_destroy(c) }
        var last: Float = 0
        var maxStep: Float = 0
        for block in 0..<2000 {
            var x = (0..<64).map { i -> Float in
                0.5 * Float(sin(2 * Double.pi * 200 * Double(block * 64 + i) / Self.sr))
            }
            var p = block % 2 == 0 ? a : b
            domine_compressor_set_params(c, &p)
            domine_compressor_process(c, &x, 64)
            for s in x {
                #expect(s.isFinite)
                maxStep = max(maxStep, abs(s - last))
                last = s
            }
        }
        #expect(maxStep < 0.1, "max step \(maxStep)")
    }
}
