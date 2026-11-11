import DomineDSP
import Foundation
import Testing

/// Speaker role and LR4 crossover (DomineCrossover.h).
struct CrossoverTests {
    static func coefficients(highpass: Bool, _ fs: Double, _ hz: Double) -> [Double] {
        var out = [Double](repeating: 0, count: 5)
        domine_crossover_coefficients(highpass ? 1 : 0, fs, hz, &out)
        return out
    }

    /// One Butterworth section's response at `hz`, as (re, im).
    static func response(_ c: [Double], _ fs: Double, _ hz: Double) -> (Double, Double) {
        let w = 2 * Double.pi * hz / fs
        // z^-1 = e^{-jw}
        let (c1, s1) = (cos(w), -sin(w))
        let (c2, s2) = (cos(2 * w), -sin(2 * w))
        let numRe = c[0] + c[1] * c1 + c[2] * c2, numIm = c[1] * s1 + c[2] * s2
        let denRe = 1 + c[3] * c1 + c[4] * c2, denIm = c[3] * s1 + c[4] * s2
        let d = denRe * denRe + denIm * denIm
        return ((numRe * denRe + numIm * denIm) / d, (numIm * denRe - numRe * denIm) / d)
    }

    static func square(_ z: (Double, Double)) -> (Double, Double) {
        (z.0 * z.0 - z.1 * z.1, 2 * z.0 * z.1)
    }

    /// Reference LR4 (two sections) over `input`, in double, same form as the C code.
    static func lr4(_ c: [Double], _ input: [Double]) -> [Double] {
        var z = [[0.0, 0.0], [0.0, 0.0]]
        return input.map { x0 in
            var x = x0
            for s in 0..<2 {
                let y = c[0] * x + z[s][0]
                z[s][0] = c[1] * x - c[3] * y + z[s][1]
                z[s][1] = c[2] * x - c[4] * y
                x = y
            }
            return x
        }
    }

    static func impulse(_ count: Int, amplitude: Float = 1) -> [Float] {
        (0..<count).map { $0 == 0 ? amplitude : 0 }
    }

    static func params(_ role: DomineSpeakerRole, _ hz: Float = 80) -> DomineCrossoverParams {
        DomineCrossoverParams(role: Int32(role.rawValue), freqHz: hz)
    }

    static func set(_ xo: OpaquePointer, _ role: DomineSpeakerRole, _ hz: Float = 80) {
        var p = params(role, hz)
        domine_crossover_set_params(xo, &p)
    }

    @Test func coefficientsAt80HzAnd48kHz() {
        let lp = Self.coefficients(highpass: false, 48000, 80)
        let expectedLP = [2.7213807988313326e-05, 5.442761597662665e-05, 2.7213807988313326e-05,
                          -1.9851906578962613, 0.9852995131282146]
        let hp = Self.coefficients(highpass: true, 48000, 80)
        let expectedHP = [0.9926225427561189, -1.9852450855122379, 0.9926225427561189,
                          -1.9851906578962613, 0.9852995131282146]
        for i in 0..<5 {
            #expect(abs(lp[i] - expectedLP[i]) < 1e-12)
            #expect(abs(hp[i] - expectedHP[i]) < 1e-12)
        }
    }

    @Test func frequencyIsClampedTo40To200Hz() {
        #expect(Self.coefficients(highpass: true, 48000, 10) == Self.coefficients(highpass: true, 48000, 40))
        #expect(Self.coefficients(highpass: false, 48000, 500) == Self.coefficients(highpass: false, 48000, 200))
        #expect(Self.coefficients(highpass: false, 48000, .nan) == Self.coefficients(highpass: false, 48000, 80))
    }

    /// LR4 low-pass plus high-pass is an allpass: flat magnitude everywhere,
    /// and each side is -6.02 dB at the crossover.
    @Test(arguments: [40.0, 80.0, 200.0])
    func lowPassPlusHighPassIsFlat(crossover: Double) {
        let fs = 48000.0
        let lp = Self.coefficients(highpass: false, fs, crossover)
        let hp = Self.coefficients(highpass: true, fs, crossover)
        for hz in [20.0, 50.0, 80.0, 100.0, 160.0, 500.0, 1000.0, 5000.0, 15000.0] {
            let a = Self.square(Self.response(lp, fs, hz))
            let b = Self.square(Self.response(hp, fs, hz))
            let magnitude = ((a.0 + b.0) * (a.0 + b.0) + (a.1 + b.1) * (a.1 + b.1)).squareRoot()
            #expect(abs(20 * log10(magnitude)) < 0.01, "at \(hz) Hz")
        }
        let atCrossover = Self.square(Self.response(lp, fs, crossover))
        let db = 20 * log10((atCrossover.0 * atCrossover.0 + atCrossover.1 * atCrossover.1).squareRoot())
        #expect(abs(db + 6.0206) < 0.01)
    }

    @Test func fullRangeIsIdleAndBitExact() {
        let xo = domine_crossover_create(48000)!
        defer { domine_crossover_destroy(xo) }
        #expect(domine_crossover_is_idle(xo) != 0)
        Self.set(xo, DOMINE_ROLE_FULL_RANGE, 120)
        var samples = TransparencyTests.signal(1024, seed: 3)
        let input = samples
        domine_crossover_process(xo, &samples, UInt32(samples.count))
        #expect(bits(samples) == bits(input))
        #expect(domine_crossover_is_idle(xo) != 0)
    }

    @Test func satelliteThenFullRangeReturnsBitExact() {
        let xo = domine_crossover_create(48000)!
        defer { domine_crossover_destroy(xo) }
        Self.set(xo, DOMINE_ROLE_SATELLITE)
        var noise = TransparencyTests.signal(2048, seed: 4)
        domine_crossover_process(xo, &noise, UInt32(noise.count))
        #expect(domine_crossover_is_idle(xo) == 0)
        Self.set(xo, DOMINE_ROLE_FULL_RANGE)
        var fade = TransparencyTests.signal(480, seed: 5)
        domine_crossover_process(xo, &fade, UInt32(fade.count)) // the 10 ms mix ramp
        #expect(domine_crossover_is_idle(xo) != 0)
        var samples = TransparencyTests.signal(1024, seed: 6)
        let input = samples
        domine_crossover_process(xo, &samples, UInt32(samples.count))
        #expect(bits(samples) == bits(input))
    }

    /// Settled satellite and subwoofer: the impulse response is the LR4
    /// high-pass and low-pass.
    @Test(arguments: [false, true])
    func settledRoleMatchesReferenceLR4(highpass: Bool) {
        let xo = domine_crossover_create(48000)!
        defer { domine_crossover_destroy(xo) }
        Self.set(xo, highpass ? DOMINE_ROLE_SATELLITE : DOMINE_ROLE_SUBWOOFER, 100)
        var silence = zeros(480)
        domine_crossover_process(xo, &silence, UInt32(silence.count))
        #expect(silence == zeros(480))
        var samples = Self.impulse(256, amplitude: 0.5)
        domine_crossover_process(xo, &samples, UInt32(samples.count))
        let expected = Self.lr4(Self.coefficients(highpass: highpass, 48000, 100),
                                Self.impulse(256, amplitude: 0.5).map(Double.init))
        for i in 0..<samples.count { #expect(abs(Double(samples[i]) - expected[i]) < 1e-7, "sample \(i)") }
    }

    // MARK: Stereo kernel

    @Test func stereoSubwooferPlaysTheMonoSumLowPassed() {
        let kernel = Kernel()
        var sub = Self.params(DOMINE_ROLE_SUBWOOFER)
        domine_kernel_set_crossover(kernel.raw, 1, &sub)
        TransparencyTests.run(kernel, left: zeros(512), right: zeros(512)) // ramps settle on silence
        let left = Self.impulse(512, amplitude: 0.5)
        let right = Self.impulse(512, amplitude: 0.25)
        let (a, b) = TransparencyTests.run(kernel, left: left, right: right)
        #expect(bits(a) == bits(left)) // the full range side keeps its own channel
        let expected = Self.lr4(Self.coefficients(highpass: false, 48000, 80),
                                Self.impulse(512, amplitude: 0.375).map(Double.init))
        for i in 0..<b.count { #expect(abs(Double(b[i]) - expected[i]) < 1e-7, "sample \(i)") }
    }

    @Test func stereoRoleBackToFullRangeIsBitExact() {
        let kernel = Kernel()
        var sat = Self.params(DOMINE_ROLE_SATELLITE)
        var sub = Self.params(DOMINE_ROLE_SUBWOOFER, 150)
        domine_kernel_set_crossover(kernel.raw, 0, &sat)
        domine_kernel_set_crossover(kernel.raw, 1, &sub)
        TransparencyTests.settle(kernel)
        var full = domine_crossover_default_params()
        domine_kernel_set_crossover(kernel.raw, 0, &full)
        domine_kernel_set_crossover(kernel.raw, 1, &full)
        TransparencyTests.settle(kernel)
        TransparencyTests.expectTransparent(kernel, seed: 21)
    }

    @Test func fullRangeRolesKeepTheKernelBitExact() {
        let kernel = Kernel()
        var full = domine_crossover_default_params()
        full.freqHz = 150
        domine_kernel_set_crossover(kernel.raw, 0, &full)
        domine_kernel_set_crossover(kernel.raw, 1, &full)
        TransparencyTests.expectTransparent(kernel, seed: 30)
    }

    // MARK: Surround kernel

    static let panLeft: [Float] = [0.5, -0.25, 1.0, 0.125, -1.0, 0.75, 0.0, 0.25]
    static let panRight: [Float] = [-0.5, 0.25, -1.0, 0.5, 1.0, -0.75, 0.5, 0.125]

    /// Width 15 puts L and R between the speakers, so a centre speaker in
    /// the panning would change the pair's gains.
    static func surround(_ azimuths: [Float]) -> OpaquePointer {
        let s = SurroundKernelTests.make(azimuths)
        domine_surround_set_width(s, 15)
        return s
    }

    /// A subwoofer at 0 degrees between a -30/+30 pair is out of VBAP: the
    /// pair plays exactly what a two-speaker layout plays, and the sub plays
    /// the low-passed mono sum on both of its channels.
    @Test func surroundSubwooferIsExcludedFromPanning() {
        let pair = Self.surround([-30, 30])
        defer { domine_surround_destroy(pair) }
        let reference = SurroundKernelTests.run(pair, offsets: [0, 2], left: Self.panLeft, right: Self.panRight)

        let s = Self.surround([-30, 30, 0])
        defer { domine_surround_destroy(s) }
        var sub = Self.params(DOMINE_ROLE_SUBWOOFER)
        domine_surround_set_crossover(s, 2, &sub)
        let out = SurroundKernelTests.run(s, offsets: [0, 2, 4], left: Self.panLeft, right: Self.panRight)
        for channel in 0..<4 { #expect(bits(out.channel(channel)) == bits(reference.channel(channel))) }
        #expect(bits(out.channel(5)) == bits(out.channel(4)))
        #expect(out.channel(4).contains { $0 != 0 })
    }

    @Test func surroundSettledSubwooferIsTheLowPassedMonoSum() {
        let s = Self.surround([-30, 30, 0])
        defer { domine_surround_destroy(s) }
        var sub = Self.params(DOMINE_ROLE_SUBWOOFER)
        domine_surround_set_crossover(s, 2, &sub)
        _ = SurroundKernelTests.run(s, offsets: [0, 2, 4], left: zeros(480), right: zeros(480))
        let out = SurroundKernelTests.run(s, offsets: [0, 2, 4], left: Self.impulse(256, amplitude: 0.5),
                                          right: Self.impulse(256, amplitude: -0.25))
        let expected = Self.lr4(Self.coefficients(highpass: false, 48000, 80),
                                Self.impulse(256, amplitude: 0.125).map(Double.init))
        let subOut = out.channel(4)
        for i in 0..<256 { #expect(abs(Double(subOut[i]) - expected[i]) < 1e-7, "sample \(i)") }
    }

    @Test func surroundFullRangeCentreTakesPartOfThePan() {
        // Control for the exclusion test: a full range centre changes the pair.
        let pair = Self.surround([-30, 30])
        defer { domine_surround_destroy(pair) }
        let reference = SurroundKernelTests.run(pair, offsets: [0, 2], left: Self.panLeft, right: Self.panRight)
        let s = Self.surround([-30, 30, 0])
        defer { domine_surround_destroy(s) }
        let out = SurroundKernelTests.run(s, offsets: [0, 2, 4], left: Self.panLeft, right: Self.panRight)
        #expect(bits(out.channel(0)) != bits(reference.channel(0)))
        #expect(out.channel(4).contains { $0 != 0 })
    }
}
