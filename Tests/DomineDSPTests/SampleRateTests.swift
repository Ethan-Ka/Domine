import CoreAudio
import DomineDSP
import Testing

/// Everything time-based in the kernel follows the rate it was created with
/// (the aggregate's rate, 44.1 kHz for freshly connected JBL Grips).
struct SampleRateTests {
    static let rate = 44_100.0

    private func ones(_ kernel: Kernel, frames: Int) -> (a: [Float], b: [Float]) {
        let input = TestBufferList.interleaved(
            left: Array(repeating: 1, count: frames), right: Array(repeating: 1, count: frames))
        let out = TestBufferList(channelsPerBuffer: [4], frames: frames)
        kernel.process(input, out)
        return (out.channel(0), out.channel(2))
    }

    @Test func delayInSamplesAt44k() {
        let kernel = Kernel(sampleRate: Self.rate)
        domine_kernel_set_delay_ms(kernel.raw, 10) // 441 samples
        let (a, b) = ones(kernel, frames: 500)
        #expect(a == Array(repeating: 1, count: 500))
        #expect(b == Array(repeating: 0, count: 441) + Array(repeating: 1, count: 59))
    }

    @Test func muteFadeLastsFiftyMillisecondsAt44k() {
        let kernel = Kernel(sampleRate: Self.rate)
        domine_kernel_set_muted(kernel.raw, 1)
        let (a, _) = ones(kernel, frames: 2300)
        let fade = 2205 // round(0.05 * 44100)
        #expect(a == (0..<2300).map { Float(max(0, fade - ($0 + 1))) / Float(fade) })
    }

    @Test func toneUsesChimeTimeAt44k() {
        let kernel = Kernel(sampleRate: Self.rate)
        domine_kernel_set_test_tone(kernel.raw, 1)
        let frames = 1764 + 441 // fade in (40 ms), then 10 ms of full tone
        let input = TestBufferList.interleaved(
            left: Array(repeating: 0, count: frames), right: Array(repeating: 0, count: frames))
        let out = TestBufferList(channelsPerBuffer: [4], frames: frames)
        kernel.process(input, out)
        let a = out.channel(0)
        for n in 1764..<frames {
            let expected = Float(ChimeReference.sample(Double(n) / Self.rate))
            #expect(abs(a[n] - expected) < 1e-5)
        }
    }

    @Test func statsReportTheKernelRate() {
        #expect(Kernel(sampleRate: Self.rate).stats().sampleRate == Self.rate)
    }
}
