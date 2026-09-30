import DomineDSP
import Foundation
import Testing

struct ToneTests {
    static func expectedTone(_ n: Int, sampleRate: Double = 48_000) -> Float {
        Float(0.25 * sin(2 * Double.pi * 1000 * Double(n) / sampleRate))
    }

    static func expectTone(_ samples: [Float], startingAt n0: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        for (i, value) in samples.enumerated() {
            let expected = expectedTone(n0 + i)
            #expect(abs(value - expected) <= 1e-6, "frame \(n0 + i)", sourceLocation: sourceLocation)
        }
    }

    @Test func toneOnAReplacesProgramAndSilencesB() {
        let kernel = Kernel()
        domine_kernel_set_test_tone(kernel.raw, 1)
        let program = Array(repeating: Float(0.5), count: 100)
        for call in 0..<3 {
            let out = TestBufferList(channelsPerBuffer: [4], frames: 100)
            kernel.process(.interleaved(left: program, right: program), out)
            Self.expectTone(out.channel(0), startingAt: call * 100)
            #expect(out.channel(1) == out.channel(0))
            #expect(out.channel(2) == zeros(100))
            #expect(out.channel(3) == zeros(100))
        }
    }

    @Test func tonePhaseIsContinuousAcrossOddCallSizes() {
        let kernel = Kernel()
        domine_kernel_set_test_tone(kernel.raw, 2)
        var n = 0
        for size in [7, 13, 1, 480, 31] {
            let out = TestBufferList(channelsPerBuffer: [4], frames: size)
            kernel.process(.interleaved(left: zeros(size), right: zeros(size)), out)
            Self.expectTone(out.channel(2), startingAt: n)
            #expect(out.channel(0) == zeros(size))
            n += size
        }
    }

    @Test func tonePositionIgnoresSwapGainAndDelay() {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 1, 1, 0)
        domine_kernel_set_gains(kernel.raw, 0.1, 0.1)
        domine_kernel_set_delay_ms(kernel.raw, -1)
        domine_kernel_set_test_tone(kernel.raw, 1)
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: 64)
        kernel.process(.interleaved(left: zeros(64), right: zeros(64)), out)
        Self.expectTone(out.channel(0), startingAt: 0)
        #expect(out.channel(2) == zeros(64))
    }

    @Test func toneRestartsAtZeroPhaseAndProgramResumes() {
        let kernel = Kernel()
        let program = Array(repeating: Float(0.5), count: 50)
        domine_kernel_set_test_tone(kernel.raw, 1)
        kernel.process(.interleaved(left: program, right: program), TestBufferList(channelsPerBuffer: [4], frames: 50))

        domine_kernel_set_test_tone(kernel.raw, 0)
        let off = TestBufferList(channelsPerBuffer: [4], frames: 50)
        kernel.process(.interleaved(left: program, right: program), off)
        #expect(off.channel(0) == program)
        #expect(off.channel(2) == program)

        domine_kernel_set_test_tone(kernel.raw, 2)
        let on = TestBufferList(channelsPerBuffer: [4], frames: 50)
        kernel.process(.interleaved(left: program, right: program), on)
        Self.expectTone(on.channel(2), startingAt: 0)
        #expect(on.channel(0) == zeros(50))
    }

    @Test func invalidToneSideIsOff() {
        let kernel = Kernel()
        domine_kernel_set_test_tone(kernel.raw, 3)
        let program = ramp(10)
        let out = TestBufferList(channelsPerBuffer: [4], frames: 10)
        kernel.process(.interleaved(left: program, right: program), out)
        #expect(out.channel(0) == program)
    }
}

struct MuteTests {
    static let fade = 2400 // 50 ms at 48 kHz

    static func run(_ kernel: Kernel, frames: Int, chunk: Int = 512, expectBEqualsA: Bool = true) -> [Float] {
        var result: [Float] = []
        var done = 0
        while done < frames {
            let n = min(chunk, frames - done)
            let ones = Array(repeating: Float(1), count: n)
            let out = TestBufferList(channelsPerBuffer: [4], frames: n)
            kernel.process(.interleaved(left: ones, right: ones), out)
            if expectBEqualsA { #expect(out.channel(2) == out.channel(0)) }
            result += out.channel(0)
            done += n
        }
        return result
    }

    @Test func startsUnmutedWithoutRamp() {
        let kernel = Kernel()
        #expect(Self.run(kernel, frames: 100) == Array(repeating: 1, count: 100))
    }

    @Test func muteRampsDownThenUp() {
        let kernel = Kernel()
        domine_kernel_set_muted(kernel.raw, 1)
        let down = Self.run(kernel, frames: 3000)
        let expectedDown = (0..<3000).map { Float(max(0, Self.fade - ($0 + 1))) / Float(Self.fade) }
        #expect(down == expectedDown)

        domine_kernel_set_muted(kernel.raw, 0)
        let up = Self.run(kernel, frames: 3000)
        let expectedUp = (0..<3000).map { Float(min(Self.fade, $0 + 1)) / Float(Self.fade) }
        #expect(up == expectedUp)
    }

    @Test func unmuteMidRampReversesFromCurrentLevel() {
        let kernel = Kernel()
        domine_kernel_set_muted(kernel.raw, 1)
        _ = Self.run(kernel, frames: 1000) // position 1400
        domine_kernel_set_muted(kernel.raw, 0)
        let up = Self.run(kernel, frames: 1200)
        let expected = (0..<1200).map { Float(min(Self.fade, 1400 + $0 + 1)) / Float(Self.fade) }
        #expect(up == expected)
    }

    @Test func muteAppliesToTone() {
        let kernel = Kernel()
        domine_kernel_set_test_tone(kernel.raw, 1)
        domine_kernel_set_muted(kernel.raw, 1)
        let out = Self.run(kernel, frames: 3000, expectBEqualsA: false)
        #expect(out.prefix(12).last! > 0.2)
        #expect(out.suffix(600).allSatisfy { $0 == 0 })
    }
}

struct PeakTests {
    @Test func peaksArePostKernelPerPosition() {
        let kernel = Kernel()
        domine_kernel_set_gains(kernel.raw, 1, 0.5)
        let out = TestBufferList(channelsPerBuffer: [4], frames: 3)
        kernel.process(.interleaved(left: [0.1, -0.9, 0.3], right: [0.2, 0.4, -0.6]), out)
        #expect(kernel.peak(0) == 0.9)
        #expect(kernel.peak(1) == 0.3)
        #expect(kernel.peak(2) == 0)
    }

    @Test func peaksReflectOnlyTheLastCycle() {
        let kernel = Kernel()
        kernel.process(.interleaved(left: [0.8], right: [-0.7]), TestBufferList(channelsPerBuffer: [4], frames: 1))
        kernel.process(.interleaved(left: [0.1], right: [-0.2]), TestBufferList(channelsPerBuffer: [4], frames: 1))
        #expect(kernel.peak(0) == 0.1)
        #expect(kernel.peak(1) == 0.2)
    }

    @Test func peaksFollowSwap() {
        let kernel = Kernel()
        domine_kernel_set_mode(kernel.raw, 1, 1, 0)
        kernel.process(.interleaved(left: [0.8], right: [-0.3]), TestBufferList(channelsPerBuffer: [4], frames: 1))
        #expect(kernel.peak(0) == 0.3)
        #expect(kernel.peak(1) == 0.8)
    }

    @Test func toneOnAShowsOnlyOnA() {
        let kernel = Kernel()
        domine_kernel_set_test_tone(kernel.raw, 1)
        let program = Array(repeating: Float(0.9), count: 48)
        kernel.process(.interleaved(left: program, right: program), TestBufferList(channelsPerBuffer: [4], frames: 48))
        #expect(kernel.peak(0) == Float(0.25))
        #expect(kernel.peak(1) == 0)
    }
}

struct FrameCountTests {
    @Test func framesBeyondMaxFramesAreProcessed() {
        let kernel = Kernel(sampleRate: 48_000, maxFrames: 16)
        let left = ramp(1000)
        let right = ramp(1000, scale: -0.001)
        let out = TestBufferList(channelsPerBuffer: [4], frames: 1000)
        kernel.process(.interleaved(left: left, right: right), out)
        #expect(out.channel(0) == left)
        #expect(out.channel(3) == right)
    }

    @Test func neverWritesPastOutputByteSize() {
        let kernel = Kernel()
        let left = ramp(20)
        let out = TestBufferList(channelsPerBuffer: [4], frames: 10, capacityFrames: 20)
        kernel.process(.interleaved(left: left, right: left), out, frames: 20)
        let a = out.channel(0)
        #expect(Array(a.prefix(10)) == Array(left.prefix(10)))
        #expect(a.suffix(10).allSatisfy { $0 == TestBufferList.sentinel })
    }

    @Test func shortInputReadsAsSilence() {
        let kernel = Kernel()
        let left = ramp(5)
        let out = TestBufferList(channelsPerBuffer: [4], frames: 10)
        kernel.process(.interleaved(left: left, right: left), out, frames: 10)
        #expect(out.channel(0) == left + zeros(5))
    }

    @Test func createRejectsBadSampleRate() {
        #expect(domine_kernel_create(0, 512) == nil)
        #expect(domine_kernel_create(-48_000, 512) == nil)
        domine_kernel_destroy(nil)
    }
}
