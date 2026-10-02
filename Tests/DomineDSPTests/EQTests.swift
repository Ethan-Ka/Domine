import DomineDSP
import Foundation
import Testing

func bits(_ a: [Float]) -> [UInt32] { a.map { $0.bitPattern } }

struct EQTests {
    static func coefficients(_ type: DomineEQBandType, _ fs: Double, _ f: Double, _ g: Double, _ q: Double) -> [Double] {
        var out = [Double](repeating: 0, count: 5)
        domine_eq_coefficients(Int32(type.rawValue), fs, f, g, q, &out)
        return out
    }

    @Test func coefficientsMatchReference() {
        let cases: [(DomineEQBandType, Double, Double, Double, Double, [Double])] = [
            (DOMINE_EQ_PEAKING, 48000, 1000, 6, 1,
             [1.04395308699034, -1.8953207239366, 0.867722284759857, -1.8953207239366, 0.911675371750192]),
            (DOMINE_EQ_LOW_SHELF, 48000, 100, -6, 0.7071,
             [0.996792395761703, -1.97805893465786, 0.981386519782781, -1.97799922843038, 0.978238621771971]),
            (DOMINE_EQ_HIGH_SHELF, 44100, 8000, 9, 0.9,
             [1.93592181872259, -1.63013203727563, 0.749994229556806, -0.237803819163549, 0.293587830167316]),
        ]
        for (type, fs, f, g, q, expected) in cases {
            let got = Self.coefficients(type, fs, f, g, q)
            for i in 0..<5 { #expect(abs(got[i] - expected[i]) < 1e-12) }
        }
    }

    @Test func zeroGainCoefficientsAreIdentity() {
        #expect(Self.coefficients(DOMINE_EQ_PEAKING, 48000, 1000, 0, 1) == [1, 0, 0, 0, 0])
    }

    @Test func flatEnabledIsBitExact() {
        let eq = domine_eq_create(48000)!
        defer { domine_eq_destroy(eq) }
        var p = domine_eq_default_params()
        p.enabled = 1
        domine_eq_set_params(eq, &p)
        var input = [Float](repeating: 0, count: 4800)
        for i in 0..<input.count {
            let wave: Float = Float(sin(Double(i) * 0.37)) * 0.9
            input[i] = i % 7 == 0 ? wave + 1.5 : wave
        }
        var buf = input
        domine_eq_process(eq, &buf, UInt32(buf.count))
        #expect(bits(buf) == bits(input))
        #expect(domine_eq_is_idle(eq) != 0)
    }

    static func setBand(_ p: inout DomineEQParams, _ i: Int, _ f: Float, _ g: Float, _ q: Float) {
        withUnsafeMutablePointer(to: &p.bands) {
            $0.withMemoryRebound(to: DomineEQBand.self, capacity: 5) { $0[i] = DomineEQBand(freqHz: f, gainDb: g, q: q) }
        }
    }

    @Test(arguments: [(2, 1000.0, 6.0), (2, 1000.0, -9.0), (1, 250.0, 12.0), (3, 4000.0, -12.0)])
    func gainAtBandCenter(band: Int, freq: Double, gain: Double) {
        let fs = 48000.0
        let eq = domine_eq_create(fs)!
        defer { domine_eq_destroy(eq) }
        var p = domine_eq_default_params()
        p.enabled = 1
        Self.setBand(&p, band, Float(freq), Float(gain), 1)
        domine_eq_set_params(eq, &p)
        let n = 48000
        var buf = (0..<n).map { Float(0.25 * sin(2 * Double.pi * freq * Double($0) / fs)) }
        domine_eq_process(eq, &buf, UInt32(n))
        // RMS over the last 0.5 s, long after the 10 ms ramp.
        let tail = buf[(n / 2)...].map { Double($0) * Double($0) }.reduce(0, +) / Double(n / 2)
        let inRms2 = 0.25 * 0.25 / 2
        let measured = 10 * log10(tail / inRms2)
        #expect(abs(measured - gain) < 0.05)
    }

    @Test func smoothingHasNoStepDiscontinuity() {
        let fs = 48000.0
        let eq = domine_eq_create(fs)!
        defer { domine_eq_destroy(eq) }
        let amp = 0.5, f = 1000.0
        var buf = (0..<9600).map { Float(amp * sin(2 * Double.pi * f * Double($0) / fs)) }
        // Switch a +12 dB peak on at sample 2400.
        domine_eq_process(eq, &buf, 2400)
        var p = domine_eq_default_params()
        p.enabled = 1
        Self.setBand(&p, 2, 1000, 12, 1)
        domine_eq_set_params(eq, &p)
        buf.withUnsafeMutableBufferPointer { domine_eq_process(eq, $0.baseAddress! + 2400, 7200) }
        var maxStep: Float = 0
        for i in 1..<buf.count { maxStep = max(maxStep, abs(buf[i] - buf[i - 1])) }
        // A steady 1 kHz sine at up to 4x gain steps by at most 4 * amp * 2 pi f / fs.
        let bound = Float(4 * amp * 2 * Double.pi * f / fs) * 1.15
        #expect(maxStep < bound)
        // And a sudden jump to the final gain would exceed what the first ramp samples show.
        #expect(abs(buf[2400] - Float(amp * sin(2 * Double.pi * f * 2400 / fs))) < 0.01)
    }

    @Test func kernelPositionsAreIndependent() {
        let kernel = Kernel()
        var p = domine_eq_default_params()
        p.enabled = 1
        Self.setBand(&p, 2, 1000, 12, 1)
        domine_kernel_set_eq(kernel.raw, 0, &p)
        let n = 4800
        let sine = (0..<n).map { Float(0.25 * sin(2 * Double.pi * 1000 * Double($0) / 48000)) }
        let out = TestBufferList(channelsPerBuffer: [4], frames: n)
        kernel.process(.interleaved(left: sine, right: sine), out)
        // Position B has no EQ: exact copy. Position A is boosted.
        #expect(bits(out.channel(2)) == bits(sine))
        #expect(bits(out.channel(3)) == bits(sine))
        let peakA = out.channel(0)[(n / 2)...].map { abs($0) }.max()!
        #expect(peakA > 0.9)
        #expect(out.channel(0) == out.channel(1))
    }

    @Test func kernelDisabledEQIsTransparent() {
        let kernel = Kernel()
        var p = domine_eq_default_params()
        Self.setBand(&p, 2, 1000, 12, 1) // gain set but not enabled
        domine_kernel_set_eq(kernel.raw, 0, &p)
        domine_kernel_set_eq(kernel.raw, 1, &p)
        let left = ramp(512), right = ramp(512, start: 3)
        let out = TestBufferList(channelsPerBuffer: [4], frames: 512)
        kernel.process(.interleaved(left: left, right: right), out)
        #expect(bits(out.channel(0)) == bits(left))
        #expect(bits(out.channel(2)) == bits(right))
    }
}
