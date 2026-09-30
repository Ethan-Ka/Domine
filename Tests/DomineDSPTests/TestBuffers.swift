import CoreAudio
import DomineDSP

/// Float32 AudioBufferList with owned storage. Each buffer is interleaved with
/// its own channel count. Storage can be larger than `mDataByteSize` so tests
/// can check the kernel never writes past the declared size.
final class TestBufferList {
    static let sentinel: Float = 9

    let list: UnsafeMutableAudioBufferListPointer
    let channelsPerBuffer: [Int]
    let capacityFrames: Int
    private let storage: [UnsafeMutablePointer<Float>]

    init(channelsPerBuffer: [Int], frames: Int, capacityFrames: Int? = nil, fill: Float = sentinel) {
        let capacity = capacityFrames ?? frames
        self.channelsPerBuffer = channelsPerBuffer
        self.capacityFrames = capacity
        list = AudioBufferList.allocate(maximumBuffers: channelsPerBuffer.count)
        var storage: [UnsafeMutablePointer<Float>] = []
        for (index, channels) in channelsPerBuffer.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: capacity * channels)
            data.initialize(repeating: fill, count: capacity * channels)
            storage.append(data)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(data))
        }
        self.storage = storage
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    var pointer: UnsafeMutablePointer<AudioBufferList> { list.unsafeMutablePointer }

    /// Samples of one channel in buffer `buffer`, over the full storage capacity.
    func samples(buffer: Int, channel: Int) -> [Float] {
        let stride = channelsPerBuffer[buffer]
        return (0..<capacityFrames).map { storage[buffer][$0 * stride + channel] }
    }

    /// Samples of a channel addressed by flat index across all buffers.
    func channel(_ flat: Int) -> [Float] {
        var base = 0
        for (buffer, channels) in channelsPerBuffer.enumerated() {
            if flat < base + channels { return samples(buffer: buffer, channel: flat - base) }
            base += channels
        }
        fatalError("channel \(flat) out of range")
    }

    var totalChannels: Int { channelsPerBuffer.reduce(0, +) }

    func setChannel(buffer: Int, channel: Int, _ values: [Float]) {
        let stride = channelsPerBuffer[buffer]
        for (frame, value) in values.enumerated() {
            storage[buffer][frame * stride + channel] = value
        }
    }

    /// Interleaved stereo tap input.
    static func interleaved(left: [Float], right: [Float]) -> TestBufferList {
        let list = TestBufferList(channelsPerBuffer: [2], frames: left.count, fill: 0)
        list.setChannel(buffer: 0, channel: 0, left)
        list.setChannel(buffer: 0, channel: 1, right)
        return list
    }

    /// Deinterleaved stereo tap input (two mono buffers).
    static func deinterleaved(left: [Float], right: [Float]) -> TestBufferList {
        let list = TestBufferList(channelsPerBuffer: [1, 1], frames: left.count, fill: 0)
        list.setChannel(buffer: 0, channel: 0, left)
        list.setChannel(buffer: 1, channel: 0, right)
        return list
    }
}

/// Owns a DomineKernel for the duration of a test.
final class Kernel {
    let raw: OpaquePointer

    init(sampleRate: Double = 48_000, maxFrames: UInt32 = 512) {
        raw = domine_kernel_create(sampleRate, maxFrames)!
    }

    deinit { domine_kernel_destroy(raw) }

    func process(_ input: TestBufferList, _ output: TestBufferList, frames: Int? = nil,
                 a: UInt32 = 0, b: UInt32 = 2) {
        let count = frames ?? input.capacityFrames
        domine_kernel_process(raw, input.pointer, output.pointer, UInt32(count), a, b)
    }

    func peak(_ position: Int32) -> Float { domine_kernel_peak(raw, position) }

    /// Runs one cycle through the IOProc entry point, as the HAL would.
    @discardableResult
    func ioproc(_ input: TestBufferList, _ output: TestBufferList) -> OSStatus {
        var now = AudioTimeStamp(), inTime = AudioTimeStamp(), outTime = AudioTimeStamp()
        return domine_kernel_ioproc(
            0, &now, input.pointer, &inTime, output.pointer, &outTime, UnsafeMutableRawPointer(raw))
    }
}

let noDevice = UInt32.max

func zeros(_ count: Int) -> [Float] { Array(repeating: 0, count: count) }

func ramp(_ count: Int, start: Int = 1, scale: Float = 0.001) -> [Float] {
    (0..<count).map { Float($0 + start) * scale }
}
