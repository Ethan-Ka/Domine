import CoreAudio
import DomineDSP
import Testing

struct QuadKernelTests {
    static let none = DOMINE_NO_DEVICE
    static let left: [Float] = [0.5, -0.25, 1.0, 0.125, -1.0, 0.75, 0.0, 0.25]
    static let right: [Float] = [-0.5, 0.25, -1.0, 0.5, 1.0, -0.75, 0.5, 0.125]
    static let frames = left.count

    /// Runs one process call. Offsets are flat channel indexes, one per position.
    static func run(
        _ q: OpaquePointer, offsets: [UInt32], left: [Float] = left, right: [Float] = right,
        buffers: [Int] = [8]
    ) -> TestBufferList {
        let input = TestBufferList.interleaved(left: left, right: right)
        let out = TestBufferList(channelsPerBuffer: buffers, frames: left.count)
        offsets.withUnsafeBufferPointer { domine_quad_process(q, input.pointer, out.pointer, UInt32(left.count), $0.baseAddress!) }
        return out
    }

    static let full: [UInt32] = [0, 2, 4, 6]

    @Test func mirrorMapping() {
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        let out = Self.run(q, offsets: Self.full)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == Self.right)
        #expect(out.channel(4) == Self.left)
        #expect(out.channel(5) == Self.left)
        #expect(out.channel(6) == Self.right)
        #expect(out.channel(7) == Self.right)
    }

    @Test func mirrorWithRearTrim() {
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        domine_quad_set_rear_trim(q, 0.5)
        let out = Self.run(q, offsets: Self.full)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(4) == Self.left.map { $0 * 0.5 })
        #expect(out.channel(7) == Self.right.map { $0 * 0.5 })
    }

    @Test func matrixMapping() {
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        domine_quad_set_rear_mode(q, Int32(DOMINE_REAR_MATRIX))
        domine_quad_set_rear_trim(q, 0.5)
        let out = Self.run(q, offsets: Self.full)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(3) == Self.right)
        let k = Float(1) / Float(1.5)
        for i in 0..<Self.frames {
            let l = Self.left[i], r = Self.right[i]
            #expect(abs(out.channel(4)[i] - k * (l - 0.5 * r) * 0.5) < 1e-6)
            #expect(abs(out.channel(5)[i] - k * (l - 0.5 * r) * 0.5) < 1e-6)
            #expect(abs(out.channel(6)[i] - k * (r - 0.5 * l) * 0.5) < 1e-6)
            #expect(abs(out.channel(7)[i] - k * (r - 0.5 * l) * 0.5) < 1e-6)
        }
    }

    @Test func matrixNeverExceedsFullScale() {
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        domine_quad_set_rear_mode(q, Int32(DOMINE_REAR_MATRIX))
        let l: [Float] = [1, -1, 1, -1, 1, 0, -1, 0.5]
        let r: [Float] = [-1, 1, -1, 1, 1, -1, -1, -0.5]
        let out = Self.run(q, offsets: Self.full, left: l, right: r)
        for c in 4..<8 {
            #expect(out.channel(c).allSatisfy { abs($0) <= 1.0 + 1e-6 })
        }
        #expect(abs(out.channel(4)[0] - 1.0) < 1e-6)
        #expect(abs(out.channel(6)[0] + 1.0) < 1e-6)
        #expect(domine_quad_peak(q, 2) <= 1.0 + 1e-6)
    }

    @Test func offsetsInSeparateBuffersAndZeroedGaps() {
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        // Buffers: [2 ch][4 ch]; FL at 4 (buffer 1 ch 2), FR at 0, RL at 2, RR at 5? offset+1 = 6 does not exist.
        let out = Self.run(q, offsets: [4, 0, 2, Self.none], buffers: [2, 4])
        #expect(out.channel(0) == Self.right)
        #expect(out.channel(1) == Self.right)
        // The lone rear plays the rear mono sum.
        let mono = zip(Self.left, Self.right).map { ($0 + $1) * 0.5 }
        #expect(out.channel(2) == mono)
        #expect(out.channel(3) == mono)
        #expect(out.channel(4) == Self.left)
        #expect(out.channel(5) == Self.left)
    }

    @Test func missingFrontFoldsToMonoSum() {
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        let mono = zip(Self.left, Self.right).map { ($0 + $1) * 0.5 }
        let out = Self.run(q, offsets: [Self.none, 0, 2, 4], buffers: [6])
        #expect(out.channel(0) == mono)
        #expect(out.channel(1) == mono)
        // Rears unchanged (mirror).
        #expect(out.channel(2) == Self.left)
        #expect(out.channel(4) == Self.right)
    }

    @Test func missingRearFoldsToRearMonoSum() {
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        let mono = zip(Self.left, Self.right).map { ($0 + $1) * 0.5 }
        let out = Self.run(q, offsets: [0, 2, Self.none, 4], buffers: [6])
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(4) == mono)
        #expect(out.channel(5) == mono)
    }

    @Test func singleSpeakerPlaysFullMono() {
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        let mono = zip(Self.left, Self.right).map { ($0 + $1) * 0.5 }
        let out = Self.run(q, offsets: [Self.none, Self.none, 2, Self.none], buffers: [4])
        #expect(out.channel(0) == [Float](repeating: 0, count: Self.frames))
        #expect(out.channel(2) == mono)
        #expect(out.channel(3) == mono)
    }

    @Test func allAbsentIsSilent() {
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        let out = Self.run(q, offsets: [Self.none, Self.none, Self.none, Self.none], buffers: [2])
        #expect(out.channel(0) == [Float](repeating: 0, count: Self.frames))
        #expect(out.channel(1) == [Float](repeating: 0, count: Self.frames))
    }

    @Test func perPositionDelayInSamples() {
        // 1000 samples/s makes 1 ms exactly 1 sample... use 48 kHz: 0.25 ms = 12 samples.
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        domine_quad_set_delay_ms(q, 1, 0.25)   // FR: 12 samples
        domine_quad_set_delay_ms(q, 3, 0.125)  // RR: 6 samples
        domine_quad_set_delay_ms(q, 2, -5)     // never negative
        let n = 32
        let l = (0..<n).map { Float($0 + 1) }
        let r = (0..<n).map { Float(-($0 + 1)) }
        let out = Self.run(q, offsets: Self.full, left: l, right: r)
        #expect(out.channel(0) == l)
        #expect(out.channel(4) == l)
        let fr = [Float](repeating: 0, count: 12) + Array(r[0..<(n - 12)])
        let rr = [Float](repeating: 0, count: 6) + Array(r[0..<(n - 6)])
        #expect(out.channel(2) == fr)
        #expect(out.channel(3) == fr)
        #expect(out.channel(6) == rr)
        #expect(out.channel(7) == rr)
    }

    @Test func perPositionGain() {
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        domine_quad_set_gain(q, 1, 0.5)
        domine_quad_set_gain(q, 2, 0.25)
        domine_quad_set_gain(q, 3, 5)  // clamps to 1
        let out = Self.run(q, offsets: Self.full)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(2) == Self.right.map { $0 * 0.5 })
        #expect(out.channel(4) == Self.left.map { $0 * 0.25 })
        #expect(out.channel(6) == Self.right)
    }

    @Test func peakPerPosition() {
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        domine_quad_set_rear_trim(q, 0.5)
        _ = Self.run(q, offsets: Self.full)
        #expect(domine_quad_peak(q, 0) == 1.0)
        #expect(domine_quad_peak(q, 1) == 1.0)
        #expect(domine_quad_peak(q, 2) == 0.5)
        #expect(domine_quad_peak(q, 7) == 0)
    }

    @Test func stereoAPIUnchanged() {
        let k = domine_kernel_create(48000, 256)!
        let q = domine_quad_create(48000, 256)!
        defer { domine_kernel_destroy(k); domine_quad_destroy(q) }
        let input = TestBufferList.interleaved(left: Self.left, right: Self.right)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.frames)
        domine_kernel_process(k, input.pointer, out.pointer, UInt32(Self.frames), 0, 2)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == Self.right)
    }

    @Test func ioprocSkipsSubDeviceInputsAndUsesLayout() {
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        var offsets = Self.full
        offsets.withUnsafeMutableBufferPointer { domine_quad_set_layout(q, 1, $0.baseAddress!) }
        domine_quad_set_input_format(q, 2, 0)
        // Buffer 0 is a sub-device input and must be ignored; buffer 1 is the tap.
        let input = TestBufferList(channelsPerBuffer: [2, 2], frames: Self.frames, fill: 0.9)
        input.setChannel(buffer: 1, channel: 0, Self.left)
        input.setChannel(buffer: 1, channel: 1, Self.right)
        let out = TestBufferList(channelsPerBuffer: [2, 2, 2, 2], frames: Self.frames)
        var t = AudioTimeStamp()
        #expect(domine_quad_ioproc(0, &t, input.pointer, &t, out.pointer, &t, UnsafeMutableRawPointer(q)) == 0)
        let expected = [Self.left, Self.left, Self.right, Self.right, Self.left, Self.left, Self.right, Self.right]
        for c in 0..<8 { #expect(out.channel(c) == expected[c]) }
    }
}
