import CoreAudio
import DomineDSP
import Testing

/// The IOProc reads whatever layout the tap delivers (SPEC section 5).
struct InputFormatTests {
    static let left: [Float] = [0.1, 0.2, 0.3, 0.4]
    static let right: [Float] = [-0.1, -0.2, -0.3, -0.4]
    static let frames = left.count

    private func render(_ kernel: Kernel, _ input: TestBufferList) -> TestBufferList {
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: Self.frames)
        kernel.ioproc(input, out)
        return out
    }

    @Test(arguments: [UInt32(0), 2])
    func interleavedStereo(formatChannels: UInt32) {
        let kernel = Kernel()
        domine_kernel_set_input_format(kernel.raw, formatChannels, 0)
        let out = render(kernel, .interleaved(left: Self.left, right: Self.right))
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == Self.right)
        #expect(kernel.stats().formatMismatchCycles == 0)
        #expect(kernel.stats().lastInputFrames == 4)
    }

    @Test func interleavedFourChannelsUsesFirstTwo() {
        let kernel = Kernel()
        domine_kernel_set_input_format(kernel.raw, 4, 0)
        let input = TestBufferList(channelsPerBuffer: [4], frames: Self.frames, fill: 0.9)
        input.setChannel(buffer: 0, channel: 0, Self.left)
        input.setChannel(buffer: 0, channel: 1, Self.right)
        let out = render(kernel, input)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(kernel.stats().lastInputFrames == 4)
        #expect(kernel.stats().formatMismatchCycles == 0)
    }

    @Test func interleavedMonoFeedsBothSides() {
        let kernel = Kernel()
        domine_kernel_set_input_format(kernel.raw, 1, 0)
        let input = TestBufferList(channelsPerBuffer: [1], frames: Self.frames)
        input.setChannel(buffer: 0, channel: 0, Self.left)
        let out = render(kernel, input)
        for channel in 0..<4 { #expect(out.channel(channel) == Self.left) }
    }

    @Test func knownMonoFormatIgnoresASecondBuffer() {
        let kernel = Kernel()
        domine_kernel_set_input_format(kernel.raw, 1, 0)
        let input = TestBufferList.deinterleaved(left: Self.left, right: Self.right)
        let out = render(kernel, input)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(2) == Self.left)
    }

    @Test(arguments: [UInt32(0), 2])
    func nonInterleavedStereo(formatChannels: UInt32) {
        let kernel = Kernel()
        domine_kernel_set_input_format(kernel.raw, formatChannels, 1)
        let out = render(kernel, .deinterleaved(left: Self.left, right: Self.right))
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == Self.right)
        #expect(kernel.stats().formatMismatchCycles == 0)
    }

    @Test func nonInterleavedFourBuffersUsesFirstTwo() {
        let kernel = Kernel()
        domine_kernel_set_input_format(kernel.raw, 4, 1)
        let input = TestBufferList(channelsPerBuffer: [1, 1, 1, 1], frames: Self.frames, fill: 0.9)
        input.setChannel(buffer: 0, channel: 0, Self.left)
        input.setChannel(buffer: 1, channel: 0, Self.right)
        let out = render(kernel, input)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(kernel.stats().formatMismatchCycles == 0)
    }

    @Test func nonInterleavedMonoFeedsBothSides() {
        let kernel = Kernel()
        domine_kernel_set_input_format(kernel.raw, 1, 1)
        let input = TestBufferList(channelsPerBuffer: [1], frames: Self.frames)
        input.setChannel(buffer: 0, channel: 0, Self.right)
        let out = render(kernel, input)
        for channel in 0..<4 { #expect(out.channel(channel) == Self.right) }
    }

    @Test func buffersWinOverAWrongFormatAndTheMismatchIsCounted() {
        let kernel = Kernel()
        domine_kernel_set_input_format(kernel.raw, 2, 1) // says deinterleaved
        let out = render(kernel, .interleaved(left: Self.left, right: Self.right))
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(kernel.stats().formatMismatchCycles == 1)
    }

    @Test func deinterleavedFramesAreTheShorterSide() {
        let kernel = Kernel()
        let input = TestBufferList.deinterleaved(left: Self.left, right: Self.right)
        input.list[1].mDataByteSize = UInt32(2 * MemoryLayout<Float>.size)
        let out = render(kernel, input)
        #expect(kernel.stats().lastInputFrames == 2)
        #expect(out.channel(0) == [0.1, 0.2, 0, 0])
        #expect(out.channel(2) == [-0.1, -0.2, 0, 0])
    }
}
