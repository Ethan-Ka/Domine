import DomineDSP
import Testing

struct MappingTests {
    static let left: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
    static let right: [Float] = [-0.1, -0.2, -0.3, -0.4, -0.5, -0.6, -0.7, -0.8]
    static let mono: [Float] = zip(left, right).map { ($0 + $1) * 0.5 }
    static let frames = left.count

    @Test func interleavedInputMonoPerSpeaker() {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.frames)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == Self.right)
    }

    @Test func deinterleavedInputMonoPerSpeaker() {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.frames)
        kernel.process(.deinterleaved(left: Self.left, right: Self.right), out)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == Self.right)
    }

    @Test func singleMonoInputBufferFeedsBothSides() {
        let kernel = Kernel()
        let input = TestBufferList(channelsPerBuffer: [1], frames: Self.frames, fill: 0)
        input.setChannel(buffer: 0, channel: 0, Self.left)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.frames)
        kernel.process(input, out)
        for channel in 0..<4 { #expect(out.channel(channel) == Self.left) }
    }

    @Test func nullInputIsSilence() {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.frames)
        domine_kernel_process(kernel.raw, nil, out.pointer, UInt32(Self.frames), 0, 2)
        for channel in 0..<4 { #expect(out.channel(channel) == zeros(Self.frames)) }
    }

    @Test func nonMonoMappingUsesFirstChannelOnly() {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 0, 0, 0)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.frames)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == zeros(Self.frames))
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == zeros(Self.frames))
    }

    @Test func swapSendsLeftToB() {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 1, 1, 0)
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.frames)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out)
        #expect(out.channel(0) == Self.right)
        #expect(out.channel(1) == Self.right)
        #expect(out.channel(2) == Self.left)
        #expect(out.channel(3) == Self.left)
    }

    @Test func monoFallbackBothPresent() {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 0, 1, 1) // monoPerSpeaker and swap ignored
        let out = TestBufferList(channelsPerBuffer: [4], frames: Self.frames)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out)
        for channel in 0..<4 { #expect(out.channel(channel) == Self.mono) }
    }

    @Test func monoFallbackWithBAbsent() {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 1, 0, 1)
        let out = TestBufferList(channelsPerBuffer: [2], frames: Self.frames)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out, a: 0, b: noDevice)
        #expect(out.channel(0) == Self.mono)
        #expect(out.channel(1) == Self.mono)
        #expect(kernel.peak(1) == 0)
    }

    @Test func monoFallbackWithAAbsent() {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 1, 1, 1) // swap ignored
        let left: [Float] = [0.5, 1, -1, 0.25]
        let right: [Float] = [0.25, 0, 0.5, -0.75]
        let out = TestBufferList(channelsPerBuffer: [2], frames: left.count)
        kernel.process(.interleaved(left: left, right: right), out, a: noDevice, b: 0)
        let expected: [Float] = [0.375, 0.5, -0.25, -0.25]
        #expect(out.channel(0) == expected)
        #expect(out.channel(1) == expected)
        #expect(kernel.peak(0) == 0)
        #expect(kernel.peak(1) == 0.5)
    }

    /// The remaining speaker keeps its own trim gain (position B here).
    @Test func monoFallbackKeepsThePresentPositionsGain() {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 1, 0, 1)
        domine_kernel_set_gains(kernel.raw, 0.25, 0.5)
        let left: [Float] = [0.5, 1, -1, 0.25]
        let right: [Float] = [0.5, 0, 1, -0.75]
        let out = TestBufferList(channelsPerBuffer: [2], frames: left.count)
        kernel.process(.interleaved(left: left, right: right), out, a: noDevice, b: 0)
        let expected: [Float] = [0.25, 0.25, 0, -0.125]
        #expect(out.channel(0) == expected)
        #expect(out.channel(1) == expected)
    }

    @Test func bAbsentZeroesItsOldChannels() {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 1, 0, 1)
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: Self.frames)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out, a: 2, b: noDevice)
        #expect(out.channel(0) == zeros(Self.frames))
        #expect(out.channel(1) == zeros(Self.frames))
        #expect(out.channel(2) == Self.mono)
        #expect(out.channel(3) == Self.mono)
    }

    @Test(arguments: [[1, 1, 1, 1], [4], [2, 2], [1, 2, 1]])
    func outputLayouts(channelsPerBuffer: [Int]) {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: channelsPerBuffer, frames: Self.frames)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out, a: 0, b: 2)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == Self.right)
    }

    @Test func deviceBFirstInLayout() {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: Self.frames)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out, a: 2, b: 0)
        #expect(out.channel(0) == Self.right)
        #expect(out.channel(1) == Self.right)
        #expect(out.channel(2) == Self.left)
        #expect(out.channel(3) == Self.left)
    }

    @Test func unusedChannelsAreZeroed() {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: [3, 4], frames: Self.frames)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out, a: 1, b: 4)
        #expect(out.channel(0) == zeros(Self.frames))
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.left)
        #expect(out.channel(3) == zeros(Self.frames))
        #expect(out.channel(4) == Self.right)
        #expect(out.channel(5) == Self.right)
        #expect(out.channel(6) == zeros(Self.frames))
    }

    @Test func offsetsPastEndAreSkipped() {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: [2, 1], frames: Self.frames)
        // B would need channels 2 and 3; only 2 exists.
        kernel.process(.interleaved(left: Self.left, right: Self.right), out, a: 0, b: 2)
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
    }
}
