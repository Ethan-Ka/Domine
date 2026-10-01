import DomineDSP
import Foundation
import Testing

struct ToneTests {
    /// 40 ms at 48 kHz.
    static let fade = 1920

    /// The bare sine, n samples after the tone (re)started at phase 0.
    static func tone(_ n: Int, sampleRate: Double = 48_000) -> Float {
        Float(DOMINE_TONE_AMPLITUDE * sin(2 * Double.pi * DOMINE_TONE_HZ * Double(n) / sampleRate))
    }

    /// The playing position at tone level `level` (0...fade) over `program`.
    static func playing(_ tone: Float, program: Float, level: Int) -> Float {
        if level == fade { return tone }
        let e = Float(level) / Float(fade)
        return tone * e + program * (1 - e)
    }

    /// The other position at tone level `level` over `program`.
    static func other(program: Float, level: Int) -> Float {
        if level == fade { return 0 }
        return program * (1 - Float(level) / Float(fade))
    }

    /// Tone level while fading in, n samples after the tone started.
    static func levelIn(_ n: Int) -> Int { min(n, fade) }

    static func expectClose(_ samples: [Float], _ expected: [Float], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(samples.count == expected.count, sourceLocation: sourceLocation)
        for (i, (value, want)) in zip(samples, expected).enumerated() where abs(value - want) > 1e-6 {
            Issue.record("sample \(i): got \(value), expected \(want)", sourceLocation: sourceLocation)
            return
        }
    }

    /// Runs the kernel in `chunk`-sized calls and returns positions A and B.
    static func run(_ kernel: Kernel, frames: Int, program: Float, chunk: Int = 512) -> (a: [Float], b: [Float]) {
        var a: [Float] = [], b: [Float] = []
        var done = 0
        while done < frames {
            let n = min(chunk, frames - done)
            let input = Array(repeating: program, count: n)
            let out = TestBufferList(channelsPerBuffer: [4], frames: n)
            kernel.process(.interleaved(left: input, right: input), out)
            #expect(out.channel(1) == out.channel(0))
            #expect(out.channel(3) == out.channel(2))
            a += out.channel(0)
            b += out.channel(2)
            done += n
        }
        return (a, b)
    }

    @Test func fadeLengthIs40Milliseconds() {
        #expect(Int(lround(48_000 * DOMINE_TONE_FADE_MS / 1000)) == Self.fade)
    }

    @Test func toneOnAFadesInOverProgramThenReplacesItAndSilencesB() {
        let kernel = Kernel()
        domine_kernel_set_test_tone(kernel.raw, 1)
        let frames = Self.fade + 300
        let (a, b) = Self.run(kernel, frames: frames, program: 0.5, chunk: 100)
        Self.expectClose(a, (0..<frames).map { Self.playing(Self.tone($0), program: 0.5, level: Self.levelIn($0)) })
        Self.expectClose(b, (0..<frames).map { Self.other(program: 0.5, level: Self.levelIn($0)) })
        #expect(a[0] == 0.5)
        #expect(b.suffix(300) == zeros(300))
    }

    @Test func tonePhaseIsContinuousAcrossOddCallSizes() {
        let kernel = Kernel()
        domine_kernel_set_test_tone(kernel.raw, 2)
        var n = 0
        for size in [7, 13, 1, 480, 31, 2000] {
            let out = TestBufferList(channelsPerBuffer: [4], frames: size)
            kernel.process(.interleaved(left: zeros(size), right: zeros(size)), out)
            Self.expectClose(out.channel(2), (n..<n + size).map { Self.playing(Self.tone($0), program: 0, level: Self.levelIn($0)) })
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
        let frames = Self.fade + 64
        let out = TestBufferList(channelsPerBuffer: [2, 2], frames: frames)
        kernel.process(.interleaved(left: zeros(frames), right: zeros(frames)), out)
        Self.expectClose(out.channel(0), (0..<frames).map { Self.playing(Self.tone($0), program: 0, level: Self.levelIn($0)) })
        #expect(out.channel(2) == zeros(frames))
    }

    @Test func toneOffFadesOutThenProgramResumes() {
        let kernel = Kernel()
        domine_kernel_set_test_tone(kernel.raw, 1)
        _ = Self.run(kernel, frames: Self.fade + 100, program: 0.5)

        domine_kernel_set_test_tone(kernel.raw, 0)
        let frames = Self.fade + 50
        let (a, b) = Self.run(kernel, frames: frames, program: 0.5)
        // Level counts down from full: fade, fade - 1, ... 1, then program only.
        let level = { (i: Int) in max(Self.fade - i, 0) }
        let n0 = Self.fade + 100
        Self.expectClose(a, (0..<frames).map { i in
            level(i) == 0 ? 0.5 : Self.playing(Self.tone(n0 + i), program: 0.5, level: level(i))
        })
        Self.expectClose(b, (0..<frames).map { Self.other(program: 0.5, level: level($0)) })
        #expect(a.suffix(50) == Array(repeating: 0.5, count: 50))
        #expect(b.suffix(50) == Array(repeating: 0.5, count: 50))
    }

    @Test func toneOffMidFadeInReversesFromCurrentLevel() {
        let kernel = Kernel()
        domine_kernel_set_test_tone(kernel.raw, 1)
        _ = Self.run(kernel, frames: 100, program: 0.5)  // level 100
        domine_kernel_set_test_tone(kernel.raw, 0)
        let (a, b) = Self.run(kernel, frames: 120, program: 0.5)
        let level = { (i: Int) in max(100 - i, 0) }
        Self.expectClose(a, (0..<120).map { i in
            level(i) == 0 ? 0.5 : Self.playing(Self.tone(100 + i), program: 0.5, level: level(i))
        })
        Self.expectClose(b, (0..<120).map { Self.other(program: 0.5, level: level($0)) })
    }

    @Test func movingTheToneFadesOutAThenFadesInBFromPhaseZero() {
        let kernel = Kernel()
        domine_kernel_set_test_tone(kernel.raw, 1)
        _ = Self.run(kernel, frames: 50, program: 0)  // level 50
        domine_kernel_set_test_tone(kernel.raw, 2)
        let (a, b) = Self.run(kernel, frames: 200, program: 0)
        // Frames 0..<50 fade A out (levels 50...1); B starts at frame 50 at level 0.
        Self.expectClose(a, (0..<200).map { i in
            i < 50 ? Self.playing(Self.tone(50 + i), program: 0, level: 50 - i) : 0
        })
        Self.expectClose(b, (0..<200).map { i in
            i < 50 ? 0 : Self.playing(Self.tone(i - 50), program: 0, level: i - 50)
        })
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
        // Program is all ones: the tone fades in over it while the mute fades both out.
        let expected = (0..<3000).map { n in
            ToneTests.playing(ToneTests.tone(n), program: 1, level: ToneTests.levelIn(n))
                * (Float(max(0, Self.fade - (n + 1))) / Float(Self.fade))
        }
        ToneTests.expectClose(out, expected)
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
        // Past the fade in, one full 440 Hz cycle (about 109 frames).
        _ = ToneTests.run(kernel, frames: ToneTests.fade, program: 0.9)
        let program = Array(repeating: Float(0.9), count: 110)
        let out = TestBufferList(channelsPerBuffer: [4], frames: 110)
        kernel.process(.interleaved(left: program, right: program), out)
        #expect(kernel.peak(0) == out.channel(0).map(abs).max())
        #expect(kernel.peak(0) > Float(DOMINE_TONE_AMPLITUDE) * 0.999)
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
