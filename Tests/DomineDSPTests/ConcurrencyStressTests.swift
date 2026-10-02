import CoreAudio
import DomineDSP
import Foundation
import Testing

/// Regression test for a crash while moving a slider during playback: the
/// render loop runs on a background thread while this thread hammers every
/// setter with random values, as the main thread does in the app. Run it
/// under Address Sanitizer and Thread Sanitizer to catch out-of-bounds
/// writes and unsynchronised parameter buffers.
struct ConcurrencyStressTests {
    static let duration: TimeInterval = 1.0

    /// Background render loop with a stop flag shared through a lock.
    final class RenderLoop: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private let done = DispatchSemaphore(value: 0)
        private(set) var cycles = 0

        var isStopped: Bool { lock.withLock { stopped } }

        func start(_ body: @escaping @Sendable () -> Void) {
            let thread = Thread { [self] in
                var n = 0
                while !isStopped {
                    body()
                    n += 1
                }
                cycles = n
                done.signal()
            }
            thread.start()
        }

        func stop() {
            lock.withLock { stopped = true }
            done.wait()
        }
    }

    /// Wraps the C handle and buffers so the render closure can capture them.
    final class Shared: @unchecked Sendable {
        let handle: OpaquePointer
        let input: TestBufferList
        let output: TestBufferList
        init(handle: OpaquePointer, input: TestBufferList, output: TestBufferList) {
            self.handle = handle
            self.input = input
            self.output = output
        }
    }

    static func noise(_ n: Int) -> [Float] { (0..<n).map { _ in Float.random(in: -1...1) } }

    static func randomFloat() -> Float {
        switch Int.random(in: 0..<12) {
        case 0: return .nan
        case 1: return .infinity
        case 2: return -.infinity
        case 3: return 0
        case 4: return Float.random(in: -1e6...1e6)
        default: return Float.random(in: -2...2)
        }
    }

    static func randomEQ() -> DomineEQParams {
        var p = domine_eq_default_params()
        p.enabled = Int32.random(in: 0...1)
        withUnsafeMutableBytes(of: &p.bands) { raw in
            let bands = raw.bindMemory(to: DomineEQBand.self)
            for i in 0..<bands.count {
                bands[i] = DomineEQBand(
                    freqHz: Bool.random() ? Float.random(in: 20...20000) : randomFloat(),
                    gainDb: Bool.random() ? Float.random(in: -12...12) : randomFloat(),
                    q: Bool.random() ? Float.random(in: 0.3...4) : randomFloat())
            }
        }
        return p
    }

    static func randomBass() -> DomineBassParams {
        DomineBassParams(enabled: Int32.random(in: 0...1), amount: Float.random(in: -0.5...1.5),
                         cutoffHz: Bool.random() ? 120 : randomFloat())
    }

    static func randomCompressor() -> DomineCompressorParams {
        DomineCompressorParams(
            enabled: Int32.random(in: 0...1), thresholdDb: Float.random(in: -60...0),
            ratio: Float.random(in: 0...20), attackMs: Float.random(in: 0...200),
            releaseMs: Float.random(in: 0...1000), makeupDb: Float.random(in: -12...24),
            limiterCeilingDb: Float.random(in: -12...0))
    }

    @Test func kernelSettersRaceRender() {
        let frames = 512
        let k = domine_kernel_create(48000, UInt32(frames))!
        defer { domine_kernel_destroy(k) }
        let shared = Shared(
            handle: k,
            input: TestBufferList.interleaved(left: Self.noise(frames), right: Self.noise(frames)),
            output: TestBufferList(channelsPerBuffer: [2, 2], frames: frames))
        domine_kernel_set_layout(k, 0, 0, 2)
        let loop = RenderLoop()
        loop.start {
            var now = stamp(host: mach_absolute_time(), sample: 0)
            var t = AudioTimeStamp(), o = AudioTimeStamp()
            _ = domine_kernel_ioproc(0, &now, shared.input.pointer, &t, shared.output.pointer, &o,
                                     UnsafeMutableRawPointer(shared.handle))
            domine_kernel_process(shared.handle, shared.input.pointer, shared.output.pointer,
                                  UInt32(frames), 0, 2)
        }

        let end = Date().addingTimeInterval(Self.duration)
        var calls = 0
        while Date() < end {
            for _ in 0..<64 {
                let pos = Int32.random(in: 0...1)
                switch Int.random(in: 0..<11) {
                case 0: domine_kernel_set_gains(k, Self.randomFloat(), Self.randomFloat())
                case 1: domine_kernel_set_delay_ms(k, Self.randomFloat() * 100)
                case 2:
                    var p = Self.randomEQ()
                    domine_kernel_set_eq(k, pos, &p)
                case 3:
                    var p = Self.randomBass()
                    domine_kernel_set_bass(k, pos, &p)
                case 4:
                    var p = Self.randomCompressor()
                    domine_kernel_set_compressor(k, pos, &p)
                case 5: domine_kernel_set_muted(k, Int32.random(in: 0...1))
                case 6: domine_kernel_set_test_tone(k, Int32.random(in: -1...3))
                case 7: domine_kernel_set_click_test(k, Int32.random(in: -1...3))
                case 8: domine_kernel_set_mode(k, Int32.random(in: 0...1), Int32.random(in: 0...1), Int32.random(in: 0...1))
                case 9: _ = domine_kernel_peak(k, pos)
                default:
                    var s = DomineKernelStats()
                    _ = domine_kernel_stats(k, &s)
                }
                calls += 1
            }
        }
        loop.stop()
        #expect(loop.cycles > 0)
        #expect(calls > 0)
        for c in 0..<4 {
            #expect(shared.output.channel(c).allSatisfy { $0.isFinite })
        }
    }

    @Test func quadSettersRaceRender() {
        let frames = 512
        let q = domine_quad_create(48000, UInt32(frames))!
        defer { domine_quad_destroy(q) }
        let shared = Shared(
            handle: q,
            input: TestBufferList.interleaved(left: Self.noise(frames), right: Self.noise(frames)),
            output: TestBufferList(channelsPerBuffer: [2, 2, 2, 2], frames: frames))
        let offsets: [UInt32] = [0, 2, 4, 6]
        offsets.withUnsafeBufferPointer { domine_quad_set_layout(q, 0, $0.baseAddress!) }
        let loop = RenderLoop()
        loop.start {
            var now = AudioTimeStamp(), t = AudioTimeStamp(), o = AudioTimeStamp()
            _ = domine_quad_ioproc(0, &now, shared.input.pointer, &t, shared.output.pointer, &o,
                                   UnsafeMutableRawPointer(shared.handle))
            offsets.withUnsafeBufferPointer {
                domine_quad_process(shared.handle, shared.input.pointer, shared.output.pointer,
                                    UInt32(frames), $0.baseAddress!)
            }
        }

        let end = Date().addingTimeInterval(Self.duration)
        var calls = 0
        while Date() < end {
            for _ in 0..<64 {
                let pos = Int32.random(in: 0...3)
                switch Int.random(in: 0..<9) {
                case 0: domine_quad_set_gain(q, pos, Self.randomFloat())
                case 1: domine_quad_set_delay_ms(q, pos, Self.randomFloat() * 100)
                case 2:
                    var p = Self.randomEQ()
                    domine_quad_set_eq(q, pos, &p)
                case 3:
                    var p = Self.randomBass()
                    domine_quad_set_bass(q, pos, &p)
                case 4:
                    var p = Self.randomCompressor()
                    domine_quad_set_compressor(q, pos, &p)
                case 5: domine_quad_set_muted(q, Int32.random(in: 0...1))
                case 6: domine_quad_set_rear_mode(q, Int32.random(in: -1...3))
                case 7: domine_quad_set_rear_trim(q, Self.randomFloat())
                default: _ = domine_quad_peak(q, pos)
                }
                calls += 1
            }
        }
        loop.stop()
        #expect(loop.cycles > 0)
        #expect(calls > 0)
        for c in 0..<8 {
            #expect(shared.output.channel(c).allSatisfy { $0.isFinite })
        }
    }
}
