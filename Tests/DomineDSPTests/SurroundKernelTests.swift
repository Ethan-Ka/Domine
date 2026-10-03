import CoreAudio
import DomineDSP
import Foundation
import Testing

/// Swift mirror of the main C tests in Tests/linux-dsp/test_surround.c.
struct SurroundKernelTests {
    static let none = DOMINE_NO_DEVICE
    static let left: [Float] = [0.5, -0.25, 1.0, 0.125, -1.0, 0.75, 0.0, 0.25]
    static let right: [Float] = [-0.5, 0.25, -1.0, 0.5, 1.0, -0.75, 0.5, 0.125]
    static let frames = left.count

    static func make(_ sampleRate: Double = 48000, _ azimuths: [Float]) -> OpaquePointer {
        let s = domine_surround_create(sampleRate, 512)!
        azimuths.withUnsafeBufferPointer { domine_surround_set_speakers(s, UInt32(azimuths.count), $0.baseAddress) }
        return s
    }

    /// Runs one process call. Offsets are flat channel indexes, one per speaker.
    static func run(
        _ s: OpaquePointer, offsets: [UInt32], left: [Float] = Self.left, right: [Float] = Self.right,
        buffers: [Int] = [8]
    ) -> TestBufferList {
        let input = TestBufferList.interleaved(left: left, right: right)
        let out = TestBufferList(channelsPerBuffer: buffers, frames: left.count)
        offsets.withUnsafeBufferPointer {
            domine_surround_process(s, input.pointer, out.pointer, UInt32(left.count), $0.baseAddress!)
        }
        return out
    }

    static func vbap(_ azimuths: [Float], present: [UInt8]? = nil, source: Float) -> [Float] {
        var gains = [Float](repeating: 0, count: azimuths.count)
        azimuths.withUnsafeBufferPointer { az in
            gains.withUnsafeMutableBufferPointer { g in
                if let present {
                    present.withUnsafeBufferPointer { p in
                        domine_surround_vbap(UInt32(azimuths.count), az.baseAddress!, p.baseAddress, source, g.baseAddress!)
                    }
                } else {
                    domine_surround_vbap(UInt32(azimuths.count), az.baseAddress!, nil, source, g.baseAddress!)
                }
            }
        }
        return gains
    }

    // MARK: VBAP

    @Test func vbapOnSpeakerAndMidpoint() {
        #expect(Self.vbap([-30, 30, -110, 110], source: 110) == [0, 0, 0, 1])
        let mid = Self.vbap([-30, 30], source: 0)
        #expect(mid[0] == mid[1])
        #expect(abs(mid[0] - Float(0.5).squareRoot()) < 1e-7)
    }

    @Test func vbapGapRuleBehindFrontPair() {
        let g = Self.vbap([-30, 30], source: 90) // 60 of the 300 degree gap past 30
        #expect(abs(g[1] - Float(cos(0.1 * Double.pi))) < 1e-6)
        #expect(abs(g[0] - Float(sin(0.1 * Double.pi))) < 1e-6)
    }

    @Test func vbapCoincidentAbsentAndSingle() {
        let co = Self.vbap([0, 0.3, 90], source: 0)
        #expect(co[0] == co[1])
        #expect(co[2] == 0)
        #expect(abs(co[0] - Float(0.5).squareRoot()) < 1e-7)
        let absent = Self.vbap([-30, 30, 0], present: [1, 1, 0], source: 0)
        #expect(absent[2] == 0)
        #expect(absent[0] == absent[1])
        #expect(Self.vbap([45], source: -170) == [1])
    }

    @Test func vbapUnitPowerSweep() {
        let layouts: [[Float]] = [[-30, 30], [-30, 30, -110, 110], [0, 72, 144, -144, -72], [10, 10.2, 170, -100]]
        for layout in layouts {
            for a in -180...180 {
                let g = Self.vbap(layout, source: Float(a))
                let power = g.reduce(0) { $0 + Double($1) * Double($1) }
                #expect(abs(power - 1) < 1e-5)
            }
        }
    }

    @Test func distanceCompensation() {
        let d: [Float] = [2, 3.43]
        var ms = [Float](repeating: 0, count: 2), g = [Float](repeating: 0, count: 2)
        domine_surround_distance_comp(2, d, &ms, &g)
        #expect(ms[1] == 0)
        #expect(g[1] == 1)
        #expect(abs(ms[0] - Float(1.43 / 343.0 * 1000.0)) < 1e-4)
        #expect(abs(g[0] - Float(2.0 / 3.43)) < 1e-6)
    }

    // MARK: Bit-exact layouts

    @Test func twoSpeakersPlayLeftAndRightBitForBit() {
        let s = Self.make([-30, 30])
        defer { domine_surround_destroy(s) }
        for _ in 0..<2 {
            let out = Self.run(s, offsets: [0, 2], buffers: [4])
            #expect(out.channel(0) == Self.left)
            #expect(out.channel(1) == Self.left)
            #expect(out.channel(2) == Self.right)
            #expect(out.channel(3) == Self.right)
        }
        #expect(domine_surround_peak(s, 0) == 1.0)
    }

    @Test func oneSpeakerPlaysMonoBitForBit() {
        let s = Self.make([77])
        defer { domine_surround_destroy(s) }
        let mono = zip(Self.left, Self.right).map { 0.5 * ($0 + $1) }
        let out = Self.run(s, offsets: [0], buffers: [2])
        #expect(out.channel(0) == mono)
        #expect(out.channel(1) == mono)
    }

    @Test func quadLayoutMatchesQuadMirror() {
        let s = Self.make([-30, 30, -110, 110])
        let q = domine_quad_create(48000, 512)!
        defer { domine_surround_destroy(s); domine_quad_destroy(q) }
        var sp = DomineSpatialParams(amount: 0, roomMs: 15, highCutHz: 5000)
        domine_surround_set_spatial(s, &sp)
        domine_surround_set_surround_level(s, 1)
        let offsets: [UInt32] = [0, 2, 4, 6]
        let a = Self.run(s, offsets: offsets)
        let input = TestBufferList.interleaved(left: Self.left, right: Self.right)
        let b = TestBufferList(channelsPerBuffer: [8], frames: Self.frames)
        offsets.withUnsafeBufferPointer {
            domine_quad_process(q, input.pointer, b.pointer, UInt32(Self.frames), $0.baseAddress!)
        }
        for c in 0..<8 { #expect(a.channel(c) == b.channel(c)) }
    }

    @Test func absentSpeakerLeavesThePairExact() {
        let s = Self.make([-30, 0, 30])
        defer { domine_surround_destroy(s) }
        let out = Self.run(s, offsets: [0, Self.none, 2], buffers: [4])
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(domine_surround_peak(s, 1) == 0)
    }

    // MARK: Gain, mute, orbit, headroom

    @Test func gainRampsOverThirtyMilliseconds() {
        let s = Self.make(1000, [-30, 30])
        defer { domine_surround_destroy(s) }
        let ones = [Float](repeating: 1, count: 60)
        _ = Self.run(s, offsets: [0, 2], left: ones, right: ones, buffers: [4])
        domine_surround_set_gain(s, 0, 0.5)
        let out = Self.run(s, offsets: [0, 2], left: ones, right: ones, buffers: [4])
        let expected: [Float] = (0..<60).map { i in
            i + 1 >= 30 ? 0.5 : 1 + (0.5 - 1) * Float(i + 1) / 30
        }
        #expect(out.channel(0) == expected)
        #expect(out.channel(2) == ones)
    }

    @Test func muteFadesOverFiftyMilliseconds() {
        let s = Self.make(1000, [-30, 30])
        defer { domine_surround_destroy(s) }
        let ones = [Float](repeating: 1, count: 100)
        domine_surround_set_muted(s, 1)
        let out = Self.run(s, offsets: [0, 2], left: ones, right: ones, buffers: [4])
        let expected: [Float] = (0..<100).map { $0 < 50 ? Float(49 - $0) / 50 : 0 }
        for c in 0..<4 { #expect(out.channel(c) == expected) }
    }

    @Test func orbitMovesTheSource() {
        let s = Self.make(1000, [0, 90, 180, -90])
        defer { domine_surround_destroy(s) }
        domine_surround_set_surround_level(s, 0)
        domine_surround_set_width(s, 90)
        domine_surround_set_orbit_rate(s, 90)
        let half = [Float](repeating: 0.5, count: 1000), zero = [Float](repeating: 0, count: 1000)
        let first = Self.run(s, offsets: [0, 2, 4, 6], left: half, right: zero)
        #expect(first.channel(0)[0] == 0.5)
        let second = Self.run(s, offsets: [0, 2, 4, 6], left: half, right: zero)
        #expect(second.channel(0)[999] == 0)
        #expect(second.channel(2)[999] == 0.5)
    }

    @Test func fullScaleInputNeverExceedsFullScale() {
        let s = Self.make([-20, 35, 100, 180, -120])
        defer { domine_surround_destroy(s) }
        domine_surround_set_surround_level(s, 1)
        domine_surround_set_orbit_rate(s, 300)
        let l: [Float] = (0..<256).map { $0 % 3 == 0 ? 1 : -1 }
        let r: [Float] = (0..<256).map { $0 % 2 == 0 ? -1 : 1 }
        for _ in 0..<10 {
            let out = Self.run(s, offsets: [0, 2, 4, 6, 8], left: l, right: r, buffers: [10])
            for c in 0..<10 { #expect(out.channel(c).allSatisfy { abs($0) <= 1 + 1e-6 }) }
        }
    }

    // MARK: Demo, test tone, click test

    @Test func demoStartsReportsAndStops() {
        let s = Self.make(8000, [-45, 45, -135, 135])
        defer { domine_surround_destroy(s) }
        domine_surround_set_surround_level(s, 0)
        let quarter = [Float](repeating: 0.25, count: 500)
        let offsets: [UInt32] = [0, 2, 4, 6]
        let program = Self.run(s, offsets: offsets, left: quarter, right: quarter).channel(0)[499]
        #expect(domine_surround_demo_status(s, nil, nil, nil) == 0)
        domine_surround_set_demo(s, 1)
        _ = Self.run(s, offsets: offsets, left: quarter, right: quarter)
        var seconds: Float = 0, azimuth: Float = 0
        var section: Int32 = -1
        #expect(domine_surround_demo_status(s, &seconds, &azimuth, &section) != 0)
        #expect(abs(seconds - 500.0 / 8000.0) < 1e-6)
        #expect(section == Int32(DOMINE_DEMO_SECTION_ROLL_CALL))
        domine_surround_set_demo(s, 0)
        let after = Self.run(s, offsets: offsets, left: quarter, right: quarter)
        #expect(domine_surround_demo_status(s, nil, nil, &section) == 0)
        #expect(section == Int32(DOMINE_DEMO_SECTION_IDLE))
        // Program is back in full after the 50 ms (400 sample) crossfade.
        #expect(after.channel(0)[499] == program)
    }

    @Test func testToneReplacesProgramOnOneSpeaker() {
        let s = Self.make(1000, [-30, 30])
        defer { domine_surround_destroy(s) }
        domine_surround_set_gain(s, 1, 0.5) // ignored by the tone
        let ones = [Float](repeating: 1, count: 100)
        _ = Self.run(s, offsets: [0, 2], left: ones, right: ones, buffers: [4])
        domine_surround_set_test_tone(s, 1)
        let out = Self.run(s, offsets: [0, 2], left: ones, right: ones, buffers: [4])
        var phase = 0.0
        for i in 0..<100 {
            let tone = Float(domine_chime_sample(phase))
            phase += 1.0 / 1000.0
            let e: Float = i < 40 ? Float(i) / 40 : 1
            let a: Float = i < 40 ? 1 - e : 0
            let b: Float = i < 40 ? tone * e + 0.5 * (1 - e) : tone
            #expect(out.channel(0)[i] == a)
            #expect(out.channel(2)[i] == b)
        }
    }

    @Test func clickTestUsesGainAndDelay() {
        let sr = 8000.0
        let s = Self.make(sr, [-30, 30])
        defer { domine_surround_destroy(s) }
        domine_surround_set_gain(s, 0, 0.5)
        domine_surround_set_delay_ms(s, 1, 1) // 8 samples
        let zero = [Float](repeating: 0, count: 400)
        _ = Self.run(s, offsets: [0, 2], left: zero, right: zero, buffers: [4])
        domine_surround_set_click_test(s, 1)
        let out = Self.run(s, offsets: [0, 2], left: zero, right: zero, buffers: [4])
        let full = 320, length = 16
        func click(_ n: Int) -> Float {
            guard n >= 0 && n < length else { return 0 }
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(length))
            return Float(DOMINE_CLICK_AMPLITUDE * window * sin(2 * Double.pi * DOMINE_CLICK_HZ * Double(n) / sr))
        }
        for f in 0..<400 {
            #expect(out.channel(0)[f] == click(f - full) * 0.5)
            #expect(out.channel(2)[f] == click(f - full - 8))
        }
    }

    // MARK: IOProc and buffers

    @Test func ioprocSkipsSubDeviceInputsAndUsesLayout() {
        let s = Self.make([-30, 30])
        defer { domine_surround_destroy(s) }
        let offsets: [UInt32] = [0, 2]
        offsets.withUnsafeBufferPointer { domine_surround_set_layout(s, 1, 2, $0.baseAddress!) }
        domine_surround_set_input_format(s, 2, 0)
        let input = TestBufferList(channelsPerBuffer: [2, 2], frames: Self.frames, fill: 0.9)
        input.setChannel(buffer: 1, channel: 0, Self.left)
        input.setChannel(buffer: 1, channel: 1, Self.right)
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: Self.frames)
        var t = AudioTimeStamp()
        #expect(domine_surround_ioproc(0, &t, input.pointer, &t, out.pointer, &t, UnsafeMutableRawPointer(s)) == 0)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == Self.right)
    }

    @Test func neverWritesPastBuffersAndZeroesUnusedChannels() {
        let s = Self.make([-30, 30, 110])
        defer { domine_surround_destroy(s) }
        let input = TestBufferList.interleaved(left: Self.left, right: Self.right)
        let out = TestBufferList(channelsPerBuffer: [3, 5], frames: 4, capacityFrames: Self.frames)
        let offsets: [UInt32] = [0, 3, 7]
        offsets.withUnsafeBufferPointer {
            domine_surround_process(s, input.pointer, out.pointer, UInt32(Self.frames), $0.baseAddress!)
        }
        for c in 0..<8 {
            let samples = out.channel(c)
            #expect(samples[4...].allSatisfy { $0 == TestBufferList.sentinel })
            #expect(samples[..<4].allSatisfy { $0 != TestBufferList.sentinel })
        }
        for c in [2, 5, 6] { #expect(out.channel(c)[..<4].allSatisfy { $0 == 0 }) }
    }
}
