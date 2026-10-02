import CoreAudio
import DomineDSP
import Testing

struct StatsTests {
    static let left: [Float] = [0.1, -0.5, 0.3, 0.2]
    static let right: [Float] = [-0.1, 0.25, -0.75, 0.4]

    @Test func newKernelHasZeroStatsAndReportsItsSetup() {
        let kernel = Kernel(sampleRate: 48_000, maxFrames: 512)
        domine_kernel_set_layout(kernel.raw, 1, 0, 2)
        domine_kernel_set_input_format(kernel.raw, 2, 0)
        let s = kernel.stats()
        #expect(s.cycles == 0)
        #expect(s.frames == 0)
        #expect(s.sampleRate == 48_000)
        #expect(s.layoutInFirstBuffer == 1)
        #expect(s.layoutOutA == 0)
        #expect(s.layoutOutB == 2)
        #expect(s.inputChannelsPerFrame == 2)
        #expect(s.inputNonInterleaved == 0)
        #expect(s.fifoCapacity == 1024)
        #expect(s.maxFrames == 512)
    }

    @Test func fifoCapacityIsTwiceMaxFramesRoundedUp() {
        #expect(Kernel(maxFrames: 4096).stats().fifoCapacity == 8192)
        #expect(Kernel(maxFrames: 600).stats().fifoCapacity == 2048)
    }

    @Test func recordsOneCycle() {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: 4)
        kernel.ioproc(.interleaved(left: Self.left, right: Self.right), out,
                      now: stamp(host: 1000),
                      inputTime: stamp(host: 900, sample: 100),
                      outputTime: stamp(host: 1500, sample: 612))
        let s = kernel.stats()
        #expect(s.cycles == 1)
        #expect(s.frames == 4)
        #expect(s.inputFrames == 4)
        #expect(s.lastFrames == 4)
        #expect(s.lastInputFrames == 4)
        #expect(s.lastInputBuffers == 1)
        #expect(s.lastInputChannels == 2)
        #expect(s.lastOutputBuffers == 2)
        #expect(s.lastOutputFramesMin == 4)
        #expect(s.nowHostTime == 1000)
        #expect(s.inputHostTime == 900)
        #expect(s.outputHostTime == 1500)
        #expect(s.inputSampleTime == 100)
        #expect(s.outputSampleTime == 612)
        #expect(s.timeFlags == 0x1F)
        #expect(s.lastInputPeak == 0.75)
        #expect(s.maxInputPeak == 0.75)
        #expect(s.fifoFill == 0)
        #expect(s.underrunFrames == 0)
        #expect(s.inputMissingCycles == 0)
        #expect(s.inputShortCycles == 0)
        #expect(s.inputLongCycles == 0)
        #expect(s.inputSilentCycles == 0)
        #expect(s.sampleTimeJumps == 0)
    }

    @Test func invalidTimeStampsAreZeroAndFlagged() {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: [4], frames: 4)
        kernel.ioproc(.interleaved(left: Self.left, right: Self.right), out,
                      now: stamp(sample: 5), inputTime: stamp(), outputTime: stamp(host: 7))
        let s = kernel.stats()
        #expect(s.timeFlags == UInt32(DOMINE_STATS_OUTPUT_HOST_VALID))
        #expect(s.nowHostTime == 0)
        #expect(s.outputHostTime == 7)
        #expect(s.outputSampleTime == 0)
    }

    @Test func countsShortLongMissingAndSilentInput() {
        let kernel = Kernel()
        let four = { TestBufferList(channelsPerBuffer: [4], frames: 4) }
        kernel.ioproc(.interleaved(left: [0.1, 0.2], right: [0.1, 0.2]), four()) // short: 2 underrun
        kernel.ioproc(.interleaved(left: Self.left + [0.5, 0.5], right: Self.right + [0.5, 0.5]), four()) // long
        kernel.ioproc(.interleaved(left: [0, 0, 0, 0], right: [0, 0, 0, 0]), four()) // silent
        domine_kernel_set_layout(kernel.raw, 5, 0, 2)
        kernel.ioproc(.interleaved(left: Self.left, right: Self.right), four()) // missing
        let s = kernel.stats()
        #expect(s.cycles == 4)
        #expect(s.frames == 16)
        #expect(s.inputFrames == 2 + 6 + 4 + 0)
        #expect(s.inputShortCycles == 1)
        #expect(s.inputLongCycles == 1)
        #expect(s.inputSilentCycles == 1)
        #expect(s.inputMissingCycles == 1)
        // Cycle 1 underruns 2; cycle 2 leaves 2 in the FIFO; cycle 3 keeps 2;
        // cycle 4 plays the 2 left and underruns 2.
        #expect(s.underrunFrames == 4)
        #expect(s.fifoFill == 0)
        #expect(s.lastInputBuffers == 0)
        #expect(s.lastInputChannels == 0)
    }

    @Test func fifoOverflowDropsOldestAndCounts() {
        let kernel = Kernel(maxFrames: 16) // FIFO of 1024
        let input = TestBufferList(channelsPerBuffer: [2], frames: 1100, fill: 0.5)
        let out = TestBufferList(channelsPerBuffer: [4], frames: 4)
        kernel.ioproc(input, out)
        let s = kernel.stats()
        #expect(s.overflowFrames == 1100 - 4 - 1024)
        #expect(s.fifoFill == 1024)
    }

    @Test func outputMismatchAndSampleTimeJumps() {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: 4)
        out.list[1].mDataByteSize = UInt32(2 * 2 * MemoryLayout<Float>.size)
        kernel.ioproc(.interleaved(left: Self.left, right: Self.right), out, outputTime: stamp(sample: 0))
        let next = TestBufferList(channelsPerBuffer: [4], frames: 4)
        kernel.ioproc(.interleaved(left: Self.left, right: Self.right), next, outputTime: stamp(sample: 4))
        kernel.ioproc(.interleaved(left: Self.left, right: Self.right), next, outputTime: stamp(sample: 10))
        let s = kernel.stats()
        #expect(s.outputMismatchCycles == 1)
        #expect(s.sampleTimeJumps == 1)
    }

    @Test func maximaTrackAndReset() {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: [4], frames: 4)
        kernel.ioproc(.interleaved(left: Self.left, right: Self.right), out, now: stamp(host: 100))
        kernel.ioproc(.interleaved(left: [0.1, 0, 0, 0], right: [0, 0, 0, 0]), out, now: stamp(host: 400))
        kernel.ioproc(.interleaved(left: [0.2, 0, 0, 0], right: [0, 0, 0, 0]), out, now: stamp(host: 500))
        var s = kernel.stats()
        #expect(s.maxCycleInterval == 300)
        #expect(s.maxInputPeak == 0.75)
        #expect(s.lastInputPeak == 0.2)
        #expect(s.maximaResets == 0)

        domine_kernel_stats_reset_maxima(kernel.raw)
        kernel.ioproc(.interleaved(left: [0.2, 0, 0, 0], right: [0, 0, 0, 0]), out, now: stamp(host: 550))
        s = kernel.stats()
        #expect(s.maxCycleInterval == 50)
        #expect(s.maxInputPeak == 0.2)
        #expect(s.maximaResets == 1)
    }

    @Test func processDoesNotRecordStats() {
        let kernel = Kernel()
        let out = TestBufferList(channelsPerBuffer: [4], frames: 4)
        kernel.process(.interleaved(left: Self.left, right: Self.right), out)
        #expect(kernel.stats().cycles == 0)
    }

    @Test func idleSnapshotIsConsistent() {
        var s = DomineKernelStats()
        let k = Kernel()
        withExtendedLifetime(k) { #expect(domine_kernel_stats(k.raw, &s) == 1) }
    }
}
