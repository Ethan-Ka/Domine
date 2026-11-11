import DomineDSP
import Foundation
import Testing

/// Band count, per-band types and the notch filter.
struct EQBandTypeTests {
    static func setType(_ p: inout DomineEQParams, _ i: Int, _ type: DomineEQBandType) {
        withUnsafeMutableBytes(of: &p.types) { $0.bindMemory(to: Int32.self)[i] = Int32(type.rawValue) }
    }

    static func setBand(_ p: inout DomineEQParams, _ i: Int, _ f: Float, _ g: Float, _ q: Float) {
        withUnsafeMutableBytes(of: &p.bands) {
            $0.bindMemory(to: DomineEQBand.self)[i] = DomineEQBand(freqHz: f, gainDb: g, q: q)
        }
    }

    @Test func capacityIsEightWithFiveDefault() {
        #expect(DOMINE_EQ_BANDS == 8)
        let p = domine_eq_default_params()
        #expect(p.bandCount == 5)
        let types = withUnsafeBytes(of: p.types) { Array($0.bindMemory(to: Int32.self)) }
        let expected: [DomineEQBandType] = [DOMINE_EQ_LOW_SHELF, DOMINE_EQ_PEAKING, DOMINE_EQ_PEAKING,
                                            DOMINE_EQ_PEAKING, DOMINE_EQ_HIGH_SHELF, DOMINE_EQ_PEAKING,
                                            DOMINE_EQ_PEAKING, DOMINE_EQ_PEAKING]
        #expect(types == expected.map { Int32($0.rawValue) })
    }

    @Test func notchCoefficientsMatchReference() {
        let cases: [(Double, Double, Double, Double, [Double])] = [
            (48000, 1000, 0, 2,
             [0.9683996212235864, -1.920229656436938, 0.9683996212235864, -1.920229656436938, 0.9367992424471726]),
            // Gain is ignored by a notch.
            (44100, 60, 7, 10,
             [0.9995727602457969, -1.9990724744264503, 0.9995727602457969, -1.9990724744264503, 0.9991455204915938]),
        ]
        for (fs, f, g, q, expected) in cases {
            let got = EQTests.coefficients(DOMINE_EQ_NOTCH, fs, f, g, q)
            for i in 0..<5 { #expect(abs(got[i] - expected[i]) < 1e-12) }
        }
    }

    @Test func movedBandCoefficientsMatchReference() {
        let cases: [(DomineEQBandType, Double, Double, Double, Double, [Double])] = [
            (DOMINE_EQ_PEAKING, 48000, 3150, 4.5, 2.5,
             [1.0395439320382955, -1.7256303047702943, 0.8439454670148618, -1.7256303047702943, 0.8834893990531573]),
            (DOMINE_EQ_LOW_SHELF, 48000, 40, -3, 0.5,
             [0.9990974311995532, -1.988620810536202, 0.989546315655523, -1.9886160794898666, 0.9886484779014116]),
        ]
        for (type, fs, f, g, q, expected) in cases {
            let got = EQTests.coefficients(type, fs, f, g, q)
            for i in 0..<5 { #expect(abs(got[i] - expected[i]) < 1e-12) }
        }
    }

    /// Runs one band at a time through the EQ and returns the output RMS in
    /// dB relative to a 1 kHz sine input, over the last half second.
    static func levelDb(_ configure: (inout DomineEQParams) -> Void, freq: Double = 1000) -> Double {
        let fs = 48000.0
        let eq = domine_eq_create(fs)!
        defer { domine_eq_destroy(eq) }
        var p = domine_eq_default_params()
        p.enabled = 1
        configure(&p)
        domine_eq_set_params(eq, &p)
        let n = 48000
        var buf = (0..<n).map { Float(0.25 * sin(2 * Double.pi * freq * Double($0) / fs)) }
        domine_eq_process(eq, &buf, UInt32(n))
        let tail = buf[(n / 2)...].map { Double($0) * Double($0) }.reduce(0, +) / Double(n / 2)
        return 10 * log10(tail / (0.25 * 0.25 / 2))
    }

    @Test func notchBandCutsItsFrequency() {
        let db = Self.levelDb { p in
            Self.setType(&p, 2, DOMINE_EQ_NOTCH)
            Self.setBand(&p, 2, 1000, 0, 2)
        }
        #expect(db < -40)
    }

    @Test func eighthBandIsActive() {
        let db = Self.levelDb { p in
            p.bandCount = 8
            Self.setBand(&p, 7, 1000, 6, 1)
        }
        #expect(abs(db - 6) < 0.05)
    }

    @Test func bandsPastCountAreBitExactNoOps() {
        let fs = 48000.0
        let eq = domine_eq_create(fs)!
        defer { domine_eq_destroy(eq) }
        var p = domine_eq_default_params()
        p.enabled = 1
        p.bandCount = 2
        Self.setBand(&p, 2, 1000, 12, 1)
        Self.setType(&p, 3, DOMINE_EQ_NOTCH)
        domine_eq_set_params(eq, &p)
        let input = (0..<4800).map { Float(0.25 * sin(Double($0) * 0.37)) }
        var buf = input
        domine_eq_process(eq, &buf, UInt32(buf.count))
        #expect(bits(buf) == bits(input))
        #expect(domine_eq_is_idle(eq) != 0)
    }

    @Test func disabledNotchIsBitExact() {
        let fs = 48000.0
        let eq = domine_eq_create(fs)!
        defer { domine_eq_destroy(eq) }
        var p = domine_eq_default_params()
        Self.setType(&p, 2, DOMINE_EQ_NOTCH)
        domine_eq_set_params(eq, &p)
        let input = (0..<4800).map { Float(0.25 * sin(Double($0) * 0.37)) }
        var buf = input
        domine_eq_process(eq, &buf, UInt32(buf.count))
        #expect(bits(buf) == bits(input))
    }
}
