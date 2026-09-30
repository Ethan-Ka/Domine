import CoreAudio
import DomineDSP
import Testing

struct IOProcTests {
    static let left: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
    static let right: [Float] = [-0.1, -0.2, -0.3, -0.4, -0.5, -0.6]
    static let frames = left.count

    @Test func defaultLayoutIsAThenB() {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: Self.frames)
        #expect(kernel.ioproc(.interleaved(left: Self.left, right: Self.right), out) == 0)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == Self.right)
    }

    @Test func usesLayoutOffsets() {
        let kernel = Kernel()
        domine_kernel_set_layout(kernel.raw, 0, 3, 0)
        let out = TestBufferList(channelsPerBuffer: [1, 1, 1, 2], frames: Self.frames)
        kernel.ioproc(.interleaved(left: Self.left, right: Self.right), out)
        #expect(out.channel(0) == Self.right)
        #expect(out.channel(1) == Self.right)
        #expect(out.channel(2) == zeros(Self.frames))
        #expect(out.channel(3) == Self.left)
        #expect(out.channel(4) == Self.left)
    }

    @Test func noDeviceBLeavesOnlyA() {
        let kernel = Kernel()
        domine_kernel_set_layout(kernel.raw, 0, 0, noDevice)
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: Self.frames)
        kernel.ioproc(.interleaved(left: Self.left, right: Self.right), out)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == zeros(Self.frames))
        #expect(out.channel(3) == zeros(Self.frames))
    }

    @Test func inFirstBufferSkipsSubDeviceInputs() {
        let kernel = Kernel()
        domine_kernel_set_layout(kernel.raw, 1, 0, 2)
        // Buffer 0 is a sub-device input (must be ignored), buffer 1 is the tap.
        let input = TestBufferList(channelsPerBuffer: [2, 2], frames: Self.frames, fill: 0.9)
        input.setChannel(buffer: 1, channel: 0, Self.left)
        input.setChannel(buffer: 1, channel: 1, Self.right)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.frames)
        kernel.ioproc(input, out)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == Self.right)
    }

    @Test func inFirstBufferWithDeinterleavedTap() {
        let kernel = Kernel()
        domine_kernel_set_layout(kernel.raw, 2, 0, 2)
        let input = TestBufferList(channelsPerBuffer: [1, 1, 1, 1], frames: Self.frames, fill: 0.9)
        input.setChannel(buffer: 2, channel: 0, Self.left)
        input.setChannel(buffer: 3, channel: 0, Self.right)
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: Self.frames)
        kernel.ioproc(input, out)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == Self.right)
    }

    @Test func inFirstBufferPastEndIsSilence() {
        let kernel = Kernel()
        domine_kernel_set_layout(kernel.raw, 1, 0, 2)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.frames)
        kernel.ioproc(.interleaved(left: Self.left, right: Self.right), out)
        for channel in 0..<4 { #expect(out.channel(channel) == zeros(Self.frames)) }
    }

    @Test func disabledStreamWithNullDataIsSilence() {
        let kernel = Kernel()
        let input = TestBufferList.interleaved(left: Self.left, right: Self.right)
        input.list[0].mData = nil
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.frames)
        kernel.ioproc(input, out)
        for channel in 0..<4 { #expect(out.channel(channel) == zeros(Self.frames)) }
    }

    @Test func framesComeFromOutputNotInput() {
        // Input holds 6 frames but the output only 4: exactly 4 are written,
        // and the ring advances by 4, which the next cycle's delay reveals.
        let kernel = Kernel(sampleRate: 1000)
        domine_kernel_set_delay_ms(kernel.raw, 2) // B delayed by 2 samples
        let first = TestBufferList(channelsPerBuffer: [4], frames: 4, capacityFrames: 6)
        kernel.ioproc(.interleaved(left: Self.left, right: Self.right), first)
        #expect(first.channel(0) == [0.1, 0.2, 0.3, 0.4, 9, 9])
        #expect(first.channel(2) == [0, 0, -0.1, -0.2, 9, 9])

        let second = TestBufferList(channelsPerBuffer: [4], frames: 2)
        kernel.ioproc(.interleaved(left: [0.7, 0.8], right: [-0.7, -0.8]), second)
        #expect(second.channel(0) == [0.7, 0.8])
        #expect(second.channel(2) == [-0.3, -0.4])
    }

    @Test func framesUseLargestOutputBuffer() {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: Self.frames)
        out.list[0].mDataByteSize = UInt32(3 * 2 * MemoryLayout<Float>.size)
        kernel.ioproc(.interleaved(left: Self.left, right: Self.right), out)
        #expect(out.channel(0) == [0.1, 0.2, 0.3, 9, 9, 9])
        #expect(out.channel(2) == Self.right)
    }

    @Test func nullClientDataDoesNothing() {
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.frames)
        let input = TestBufferList.interleaved(left: Self.left, right: Self.right)
        var now = AudioTimeStamp(), inTime = AudioTimeStamp(), outTime = AudioTimeStamp()
        let status = domine_kernel_ioproc(0, &now, input.pointer, &inTime, out.pointer, &outTime, nil)
        #expect(status == 0)
        #expect(out.channel(0) == Array(repeating: TestBufferList.sentinel, count: Self.frames))
    }

    @Test func matchesAudioDeviceIOProcType() {
        let proc: AudioDeviceIOProc = domine_kernel_ioproc
        _ = proc
    }
}
