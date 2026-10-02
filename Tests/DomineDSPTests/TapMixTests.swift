import CoreAudio
import DomineDSP
import Testing

struct TapMixTests {
    static let l1: [Float] = [0.5, -0.25, 1.0, 0.125, -1.0, 0.75, 0.0, 0.25]
    static let r1: [Float] = [-0.5, 0.25, -1.0, 0.5, 1.0, -0.75, 0.5, 0.125]
    static let l2: [Float] = [0.25, 0.25, -0.5, 0.0, 0.5, 0.125, -0.125, 0.5]
    static let r2: [Float] = [0.125, -0.5, 0.25, 0.25, -0.25, 0.5, 0.5, -0.5]
    static let n = 8

    /// Two interleaved stereo taps in buffers 0 and 1.
    static func twoTaps() -> TestBufferList {
        let list = TestBufferList(channelsPerBuffer: [2, 2], frames: n, fill: 0)
        list.setChannel(buffer: 0, channel: 0, l1)
        list.setChannel(buffer: 0, channel: 1, r1)
        list.setChannel(buffer: 1, channel: 0, l2)
        list.setChannel(buffer: 1, channel: 1, r2)
        return list
    }

    static func layout(_ count: UInt32, first: [UInt32], channels: [UInt32], interleaved: [UInt32],
                       set: (UInt32, UnsafePointer<UInt32>?, UnsafePointer<UInt32>?, UnsafePointer<UInt32>?) -> Void) {
        first.withUnsafeBufferPointer { f in
            channels.withUnsafeBufferPointer { c in
                interleaved.withUnsafeBufferPointer { i in
                    set(count, f.baseAddress, c.baseAddress, i.baseAddress)
                }
            }
        }
    }

    static func kernelLayout(_ k: Kernel, _ count: UInt32, first: [UInt32], channels: [UInt32], interleaved: [UInt32]) {
        layout(count, first: first, channels: channels, interleaved: interleaved) {
            domine_kernel_set_tap_layout(k.raw, $0, $1, $2, $3)
        }
    }

    @Test func singleTapIsBitExact() {
        let plain = Kernel()
        let tapped = Kernel()
        Self.kernelLayout(tapped, 1, first: [0], channels: [2], interleaved: [1])
        domine_kernel_set_tap_gain(tapped.raw, 0, 1)
        let a = TestBufferList(channelsPerBuffer: [4], frames: Self.n)
        let b = TestBufferList(channelsPerBuffer: [4], frames: Self.n)
        plain.process(.interleaved(left: Self.l1, right: Self.r1), a)
        tapped.process(.interleaved(left: Self.l1, right: Self.r1), b)
        for c in 0..<4 {
            #expect(a.channel(c).map(\.bitPattern) == b.channel(c).map(\.bitPattern))
        }
    }

    @Test func twoTapsSumWithGains() {
        let k = Kernel()
        Self.kernelLayout(k, 2, first: [0, 1], channels: [2, 2], interleaved: [1, 1])
        domine_kernel_set_tap_gain(k.raw, 0, 0.5)
        domine_kernel_set_tap_gain(k.raw, 1, 0.25)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.n)
        k.process(Self.twoTaps(), out)
        let expectL = (0..<Self.n).map { Self.l1[$0] * 0.5 + Self.l2[$0] * 0.25 }
        let expectR = (0..<Self.n).map { Self.r1[$0] * 0.5 + Self.r2[$0] * 0.25 }
        #expect(out.channel(0) == expectL)
        #expect(out.channel(1) == expectL)
        #expect(out.channel(2) == expectR)
        #expect(out.channel(3) == expectR)
    }

    @Test func deinterleavedAndMonoTaps() {
        let k = Kernel()
        // Tap 0: two mono buffers (L, R). Tap 1: one mono buffer feeding both sides.
        Self.kernelLayout(k, 2, first: [0, 2], channels: [2, 1], interleaved: [0, 1])
        let list = TestBufferList(channelsPerBuffer: [1, 1, 1], frames: Self.n, fill: 0)
        list.setChannel(buffer: 0, channel: 0, Self.l1)
        list.setChannel(buffer: 1, channel: 0, Self.r1)
        list.setChannel(buffer: 2, channel: 0, Self.l2)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.n)
        k.process(list, out)
        #expect(out.channel(0) == (0..<Self.n).map { Self.l1[$0] + Self.l2[$0] })
        #expect(out.channel(2) == (0..<Self.n).map { Self.r1[$0] + Self.l2[$0] })
    }

    @Test func gainRampsOver20ms() {
        let k = Kernel()
        Self.kernelLayout(k, 1, first: [0], channels: [2], interleaved: [1])
        let ones = [Float](repeating: 1, count: 1200)
        let out = TestBufferList(channelsPerBuffer: [4], frames: 1200)
        k.process(.interleaved(left: ones, right: ones), out)
        #expect(out.channel(0) == ones)
        domine_kernel_set_tap_gain(k.raw, 0, 0.5)
        let out2 = TestBufferList(channelsPerBuffer: [4], frames: 1200)
        k.process(.interleaved(left: ones, right: ones), out2)
        let got = out2.channel(0)
        for i in [1, 100, 480, 959] {
            let expected = 1 + (0.5 - 1) * Float(i) / 960
            #expect(abs(got[i - 1] - expected) < 1e-6)
        }
        #expect(got[959] == 0.5)
        #expect(got[1199] == 0.5)
        #expect(got[0] < 1 && got[0] > 0.99)
    }

    @Test func missingAndShortBuffersAreSafe() {
        let k = Kernel()
        // Tap 1 points past the list, tap 2 at a short buffer.
        Self.kernelLayout(k, 3, first: [0, 9, 1], channels: [2, 2, 2], interleaved: [1, 1, 1])
        let list = TestBufferList(channelsPerBuffer: [2, 2], frames: Self.n, fill: 0)
        list.setChannel(buffer: 0, channel: 0, Self.l1)
        list.setChannel(buffer: 0, channel: 1, Self.r1)
        list.setChannel(buffer: 1, channel: 0, Self.l2)
        list.list[1].mDataByteSize = UInt32(2 * 2 * MemoryLayout<Float>.size)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.n)
        k.process(list, out)
        let got = out.channel(0)
        #expect(Array(got[0..<2]) == [Self.l1[0] + Self.l2[0], Self.l1[1] + Self.l2[1]])
        #expect(Array(got[2...]) == Array(Self.l1[2...]))
        // No input list at all.
        let silent = TestBufferList(channelsPerBuffer: [4], frames: Self.n)
        domine_kernel_process(k.raw, nil, silent.pointer, UInt32(Self.n), 0, 2)
        #expect(silent.channel(0) == [Float](repeating: 0, count: Self.n))
    }

    @Test func tapCountIsBoundedToEight() {
        let k = Kernel()
        let first: [UInt32] = Array(0..<12)
        Self.kernelLayout(k, 12, first: first, channels: [UInt32](repeating: 1, count: 12),
                          interleaved: [UInt32](repeating: 1, count: 12))
        let list = TestBufferList(channelsPerBuffer: [Int](repeating: 1, count: 12), frames: 1, fill: 0)
        for b in 0..<12 { list.setChannel(buffer: b, channel: 0, [0.0625]) }
        let out = TestBufferList(channelsPerBuffer: [4], frames: 1)
        k.process(list, out)
        #expect(out.channel(0) == [0.5])
        // Gains past the eighth tap are ignored without effect.
        domine_kernel_set_tap_gain(k.raw, 8, 0)
        domine_kernel_set_tap_gain(k.raw, 99, 0)
    }

    @Test func quadSingleTapBitExactAndTwoTapsSum() {
        let offsets: [UInt32] = [0, 2, 4, 6]
        func run(_ q: OpaquePointer, _ input: TestBufferList) -> TestBufferList {
            let out = TestBufferList(channelsPerBuffer: [8], frames: Self.n)
            offsets.withUnsafeBufferPointer { domine_quad_process(q, input.pointer, out.pointer, UInt32(Self.n), $0.baseAddress!) }
            return out
        }
        let plain = domine_quad_create(48000, 256)!
        let tapped = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(plain); domine_quad_destroy(tapped) }
        Self.layout(1, first: [0], channels: [2], interleaved: [1]) { domine_quad_set_tap_layout(tapped, $0, $1, $2, $3) }
        let a = run(plain, .interleaved(left: Self.l1, right: Self.r1))
        let b = run(tapped, .interleaved(left: Self.l1, right: Self.r1))
        for c in 0..<8 { #expect(a.channel(c).map(\.bitPattern) == b.channel(c).map(\.bitPattern)) }

        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        Self.layout(2, first: [0, 1], channels: [2, 2], interleaved: [1, 1]) { domine_quad_set_tap_layout(q, $0, $1, $2, $3) }
        domine_quad_set_tap_gain(q, 0, 0.5)
        domine_quad_set_tap_gain(q, 1, 0.25)
        let out = run(q, Self.twoTaps())
        #expect(out.channel(0) == (0..<Self.n).map { Self.l1[$0] * 0.5 + Self.l2[$0] * 0.25 })
        #expect(out.channel(2) == (0..<Self.n).map { Self.r1[$0] * 0.5 + Self.r2[$0] * 0.25 })
        #expect(out.channel(4) == out.channel(0))

        // Ramp: gain to 0 reaches 0 after 960 frames; also short/missing taps are safe.
        domine_quad_set_tap_gain(q, 0, 0)
        domine_quad_set_tap_gain(q, 1, 0)
        let ones = [Float](repeating: 1, count: 1200)
        let list = TestBufferList(channelsPerBuffer: [2, 2], frames: 1200, fill: 1)
        let ramp = TestBufferList(channelsPerBuffer: [8], frames: 1200)
        offsets.withUnsafeBufferPointer { domine_quad_process(q, list.pointer, ramp.pointer, 1200, $0.baseAddress!) }
        #expect(ramp.channel(0)[1199] == 0)
        #expect(ramp.channel(0)[0] > 0.74)
        _ = ones
        domine_quad_set_tap_gain(q, 99, 0)
        let none = TestBufferList(channelsPerBuffer: [8], frames: Self.n)
        offsets.withUnsafeBufferPointer { domine_quad_process(q, nil, none.pointer, UInt32(Self.n), $0.baseAddress!) }
        #expect(none.channel(0) == [Float](repeating: 0, count: Self.n))
    }
}
