import CoreAudio
import Foundation

/// Float32 AudioBufferList with owned storage, one interleaved buffer per
/// entry of `channelsPerBuffer`, for driving the engine's IOProc in tests.
final class FakeBufferList: @unchecked Sendable {
    let list: UnsafeMutableAudioBufferListPointer
    let channelsPerBuffer: [Int]
    let frames: Int
    private let storage: [UnsafeMutablePointer<Float>]

    init(channelsPerBuffer: [Int], frames: Int, fill: Float = 0) {
        self.channelsPerBuffer = channelsPerBuffer
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: max(1, channelsPerBuffer.count))
        list.count = channelsPerBuffer.count
        var storage: [UnsafeMutablePointer<Float>] = []
        for (index, channels) in channelsPerBuffer.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
            data.initialize(repeating: fill, count: frames * channels)
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

    func set(buffer: Int, channel: Int, _ values: [Float]) {
        let stride = channelsPerBuffer[buffer]
        for (frame, value) in values.enumerated() { storage[buffer][frame * stride + channel] = value }
    }

    /// Samples of a channel addressed by flat index across all buffers.
    func channel(_ flat: Int) -> [Float] {
        var base = 0
        for (buffer, channels) in channelsPerBuffer.enumerated() {
            if flat < base + channels {
                return (0..<frames).map { storage[buffer][$0 * channels + flat - base] }
            }
            base += channels
        }
        fatalError("channel \(flat) out of range")
    }

    var totalChannels: Int { channelsPerBuffer.reduce(0, +) }
}
