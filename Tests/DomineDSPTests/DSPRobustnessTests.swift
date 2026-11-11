import DomineDSP
import Foundation
import Testing

/// Bad parameters, NaN or infinite samples, and long decays must never leave
/// an effect in a poisoned or subnormal state.
struct DSPRobustnessTests {
    static let sr = 48_000.0

    static func sine(_ n: Int) -> [Float] { (0..<n).map { 0.5 * Float(sin(Double($0) * 0.05)) } }

    static func noise(_ n: Int) -> [Float] {
        var s: UInt32 = 1
        return (0..<n).map { _ in
            s = s &* 1664525 &+ 1013904223
            return Float(s >> 8) / Float(1 << 24) * 2 - 1
        }
    }

    // MARK: Compressor parameters

    @Test func compressorNonFiniteParamsTakeDefaults() {
        var p = DomineCompressorParams(enabled: 1, thresholdDb: .nan, ratio: .infinity, attackMs: .nan,
                                       releaseMs: -.infinity, makeupDb: .nan, limiterCeilingDb: .infinity)
        let q = domine_compressor_sanitize(&p)
        #expect(q.enabled == 1)
        #expect(q.thresholdDb == -18)
        #expect(q.ratio == 3)
        #expect(q.attackMs == 10)
        #expect(q.releaseMs == 100)
        #expect(q.makeupDb == 0)
        #expect(q.limiterCeilingDb == -1)
    }

    @Test func compressorParamsClampToRange() {
        var low = DomineCompressorParams(enabled: 7, thresholdDb: -200, ratio: 0.5, attackMs: -5,
                                         releaseMs: -1, makeupDb: -50, limiterCeilingDb: -100)
        let a = domine_compressor_sanitize(&low)
        #expect(a.enabled == 1)
        #expect(a.thresholdDb == -80)
        #expect(a.ratio == 1)
        #expect(a.attackMs == 0)
        #expect(a.releaseMs == 0)
        #expect(a.makeupDb == -24)
        #expect(a.limiterCeilingDb == -60)

        var high = DomineCompressorParams(enabled: 0, thresholdDb: 5, ratio: 1000, attackMs: 1e6,
                                          releaseMs: 1e7, makeupDb: 50, limiterCeilingDb: 3)
        let b = domine_compressor_sanitize(&high)
        #expect(b.enabled == 0)
        #expect(b.thresholdDb == 0)
        #expect(b.ratio == 100)
        #expect(b.attackMs == 2000)
        #expect(b.releaseMs == 5000)
        #expect(b.makeupDb == 24)
        #expect(b.limiterCeilingDb == 0)
    }

    @Test func compressorWithNaNParamsStillPassesQuietAudio() {
        // All defaults after sanitising: -40 dB sits below the knee, so gain is exactly 0 dB.
        let c = domine_compressor_create(Self.sr)!
        defer { domine_compressor_destroy(c) }
        var p = DomineCompressorParams(enabled: 1, thresholdDb: .nan, ratio: .nan, attackMs: .nan,
                                       releaseMs: .nan, makeupDb: .nan, limiterCeilingDb: .nan)
        domine_compressor_set_params(c, &p)
        let input: [Float] = [0.01, -0.01, 0.005, 0, -0.002, 0.01]
        var x = input
        domine_compressor_process(c, &x, UInt32(x.count))
        #expect(bits(x) == bits(input))
    }

    @Test func compressorNaNInputComesOutSilentAndLeavesStateClean() {
        let c = domine_compressor_create(Self.sr)!
        defer { domine_compressor_destroy(c) }
        var p = DomineCompressorParams(enabled: 1, thresholdDb: -18, ratio: 4, attackMs: 10,
                                       releaseMs: 100, makeupDb: 0, limiterCeilingDb: 0)
        domine_compressor_set_params(c, &p)
        var x: [Float] = [0.01, .nan, .infinity, -.infinity, 0.01, -0.01]
        domine_compressor_process(c, &x, UInt32(x.count))
        #expect(bits(x) == bits([0.01, 0, 0, 0, 0.01, -0.01]))
    }

    // MARK: Bass

    @Test func bassNaNInputResetsState() {
        let b = domine_bass_create(Self.sr)!
        defer { domine_bass_destroy(b) }
        var p = DomineBassParams(enabled: 1, amount: 1, cutoffHz: 120)
        domine_bass_set_params(b, &p)
        var warm = Self.sine(4096)
        domine_bass_process(b, &warm, UInt32(warm.count))
        var x: [Float] = [.nan, 0, 0, 0, .infinity, 0, -.infinity, 0]
        domine_bass_process(b, &x, UInt32(x.count))
        #expect(bits(x) == bits([Float](repeating: 0, count: 8)))
    }

    @Test func bassDecayNeverGoesSubnormalAndReachesZero() {
        let b = domine_bass_create(Self.sr)!
        defer { domine_bass_destroy(b) }
        var p = DomineBassParams(enabled: 1, amount: 1, cutoffHz: 120)
        domine_bass_set_params(b, &p)
        var x = [Float](repeating: 0, count: 96_000)
        x[0] = 0.5
        domine_bass_process(b, &x, UInt32(x.count))
        #expect(!x.contains { $0.isSubnormal })
        #expect(bits(Array(x[48_000...])) == bits([Float](repeating: 0, count: 48_000)))
    }

    // MARK: EQ

    static func peakingEQ() -> OpaquePointer {
        let eq = domine_eq_create(sr)!
        var p = domine_eq_default_params()
        p.enabled = 1
        p.bands.2.gainDb = 6
        domine_eq_set_params(eq, &p)
        var settle = [Float](repeating: 0, count: 4800) // past the 10 ms ramp
        domine_eq_process(eq, &settle, UInt32(settle.count))
        return eq
    }

    @Test func eqNaNInputClearsState() {
        let eq = Self.peakingEQ()
        defer { domine_eq_destroy(eq) }
        var warm = Self.sine(4096)
        domine_eq_process(eq, &warm, UInt32(warm.count))
        var x: [Float] = [.nan, 0, 0, 0, .infinity, 0]
        domine_eq_process(eq, &x, UInt32(x.count))
        #expect(bits(x) == bits([Float](repeating: 0, count: 6)))
    }

    @Test func eqDecayNeverGoesSubnormalAndReachesZero() {
        let eq = Self.peakingEQ()
        defer { domine_eq_destroy(eq) }
        var x = [Float](repeating: 0, count: 48_000)
        x[0] = 0.5
        domine_eq_process(eq, &x, UInt32(x.count))
        #expect(!x.contains { $0.isSubnormal })
        #expect(bits(Array(x[24_000...])) == bits([Float](repeating: 0, count: 24_000)))
    }

    // MARK: Spatial

    static func wetSpatial() -> OpaquePointer {
        let sp = domine_spatial_create(sr)!
        var p = DomineSpatialParams(amount: 1, roomMs: 15, highCutHz: 5000)
        domine_spatial_set_params(sp, &p)
        let z = [Float](repeating: 0, count: 24_000)
        var rl = z, rr = z
        domine_spatial_process(sp, z, z, &rl, &rr, UInt32(z.count))
        return sp
    }

    @Test func spatialNaNInputNeverReachesTheAmbience() {
        let sp = Self.wetSpatial()
        defer { domine_spatial_destroy(sp) }
        var l = [Float](repeating: 0, count: 4800), r = l
        l[0] = .nan
        l[3] = .infinity
        r[5] = -.infinity
        var rl = l, rr = l
        domine_spatial_process(sp, l, r, &rl, &rr, UInt32(l.count))
        // Only the bad samples' own direct path (0 * NaN) is non-finite; the
        // ambience stays silent, so every later rear sample is exactly 0.
        for i in 0..<l.count {
            if i == 0 || i == 3 { #expect(rl[i].isNaN) } else { #expect(rl[i] == 0) }
            if i == 5 { #expect(rr[i].isNaN) } else { #expect(rr[i] == 0) }
        }
    }

    @Test func spatialDecayNeverGoesSubnormalAndReachesZero() {
        let sp = Self.wetSpatial()
        defer { domine_spatial_destroy(sp) }
        let n = 96_000
        var l = [Float](repeating: 0, count: n), r = l
        let a = Self.noise(9600)
        for i in 0..<4800 { l[i] = a[2 * i]; r[i] = a[2 * i + 1] }
        var rl = l, rr = l
        domine_spatial_process(sp, l, r, &rl, &rr, UInt32(n))
        #expect(!rl.contains { $0.isSubnormal })
        #expect(!rr.contains { $0.isSubnormal })
        let zeros = [Float](repeating: 0, count: 48_000)
        #expect(bits(Array(rl[48_000...])) == bits(zeros))
        #expect(bits(Array(rr[48_000...])) == bits(zeros))
    }

    // MARK: Surround

    static func surround(_ azimuths: [Float], sampleRate: Double = 48_000) -> OpaquePointer {
        let s = domine_surround_create(sampleRate, 512)!
        azimuths.withUnsafeBufferPointer { domine_surround_set_speakers(s, UInt32(azimuths.count), $0.baseAddress) }
        domine_surround_set_surround_level(s, 0)
        return s
    }

    static func runPair(_ s: OpaquePointer, left: [Float], right: [Float]) -> TestBufferList {
        let input = TestBufferList.interleaved(left: left, right: right)
        let out = TestBufferList(channelsPerBuffer: [4], frames: left.count)
        let offsets: [UInt32] = [0, 2]
        offsets.withUnsafeBufferPointer {
            domine_surround_process(s, input.pointer, out.pointer, UInt32(left.count), $0.baseAddress!)
        }
        return out
    }

    static let left: [Float] = [0.5, -0.25, 1.0, 0.125, -1.0, 0.75, 0.0, 0.25]
    static let right: [Float] = [-0.5, 0.25, -1.0, 0.5, 1.0, -0.75, 0.5, 0.125]

    static func expectProgram(_ s: OpaquePointer, sourceLocation: SourceLocation = #_sourceLocation) {
        for _ in 0..<3 {
            let out = runPair(s, left: left, right: right)
            #expect(bits(out.channel(0)) == bits(left), sourceLocation: sourceLocation)
            #expect(bits(out.channel(1)) == bits(left), sourceLocation: sourceLocation)
            #expect(bits(out.channel(2)) == bits(right), sourceLocation: sourceLocation)
            #expect(bits(out.channel(3)) == bits(right), sourceLocation: sourceLocation)
        }
    }

    @Test func surroundToneIndexPastSpeakerCountIsOff() {
        let s = Self.surround([-30, 30])
        defer { domine_surround_destroy(s) }
        domine_surround_set_test_tone(s, 5)
        Self.expectProgram(s)
        domine_surround_set_test_tone(s, 2)
        Self.expectProgram(s)
    }

    @Test func surroundCalibrationPairPastSpeakerCountIsOff() {
        let s = Self.surround([-30, 30])
        defer { domine_surround_destroy(s) }
        domine_surround_set_calibration_pair(s, 0, 5)
        Self.expectProgram(s)
        domine_surround_set_calibration_pair(s, 3, 4)
        Self.expectProgram(s)
    }

    @Test func surroundStartFadedOutFadesInFromSilence() {
        let s = Self.surround([-30, 30], sampleRate: 1000) // 50-sample fade
        defer { domine_surround_destroy(s) }
        let ones = [Float](repeating: 1, count: 100)
        let expected: [Float] = (0..<100).map { $0 < 49 ? Float($0 + 1) / Float(50) : 1 }
        domine_surround_start_faded_out(s)
        let first = Self.runPair(s, left: ones, right: ones)
        for c in 0..<4 { #expect(bits(first.channel(c)) == bits(expected)) }
        // Again while running: the request crosses to the render thread atomically.
        domine_surround_start_faded_out(s)
        let second = Self.runPair(s, left: ones, right: ones)
        for c in 0..<4 { #expect(bits(second.channel(c)) == bits(expected)) }
        let third = Self.runPair(s, left: ones, right: ones)
        for c in 0..<4 { #expect(bits(third.channel(c)) == bits(ones)) }
    }
}
