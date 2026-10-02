/// Where the kernel reads and writes inside the aggregate's buffer lists.
///
/// Output: sub-device output channels appear in sub-device order, so A's
/// channels come first and B's follow. Offsets are flat channel indexes.
/// Input: sub-device input buffers come first, then the tap's buffers.
struct AggregateLayout: Equatable, Sendable {
    /// Index of the tap's first buffer in the aggregate's input list.
    let inFirstBuffer: Int
    /// Number of input buffers that belong to the tap.
    let tapBuffers: Int
    /// nil when the aggregate has no Device A (mono fallback).
    var outAChannelOffset: Int? { outOffsets[0] }
    /// nil when the aggregate has no Device B (mono fallback).
    var outBChannelOffset: Int? { outOffsets.count > 1 ? outOffsets[1] : nil }
    /// One flat channel offset per position (A, B in stereo; one per speaker
    /// in list order in surround). nil when that position is absent.
    let outOffsets: [Int?]

    init(inFirstBuffer: Int, tapBuffers: Int, outAChannelOffset: Int?, outBChannelOffset: Int?) {
        self.init(inFirstBuffer: inFirstBuffer, tapBuffers: tapBuffers,
                  outOffsets: [outAChannelOffset, outBChannelOffset])
    }

    init(inFirstBuffer: Int, tapBuffers: Int, outOffsets: [Int?]) {
        self.inFirstBuffer = inFirstBuffer
        self.tapBuffers = tapBuffers
        self.outOffsets = outOffsets
    }

    /// Layout for N output sub-devices in position order. A nil entry is an
    /// absent position; at least one must be present. Present sub-devices
    /// appear in the aggregate in position order.
    static func compute(
        outputs: [[Int]?],
        subDeviceInputBuffers: Int,
        aggregateOutput: [Int],
        aggregateInput: [Int]
    ) throws(EngineError) -> AggregateLayout {
        let present = outputs.compactMap { $0 }
        let expected = present.map { $0.reduce(0, +) }
        guard !present.isEmpty, expected.allSatisfy({ $0 >= 1 }),
              aggregateOutput.reduce(0, +) == expected.reduce(0, +) else {
            throw .layoutMismatch("output channels: sub-devices \(outputs), aggregate \(aggregateOutput)")
        }
        let tapBuffers = aggregateInput.count - subDeviceInputBuffers
        guard tapBuffers >= 1 else {
            throw .layoutMismatch(
                "input buffers: \(subDeviceInputBuffers) from sub-devices, aggregate \(aggregateInput), no tap stream")
        }
        var next = 0
        let offsets: [Int?] = outputs.map { streams in
            guard let streams else { return nil }
            defer { next += streams.reduce(0, +) }
            return next
        }
        return AggregateLayout(inFirstBuffer: subDeviceInputBuffers, tapBuffers: tapBuffers, outOffsets: offsets)
    }

    /// Computes the layout from the sub-devices' stream configurations and
    /// checks it against what the aggregate reports. A nil device is absent;
    /// at least one must be present. The present devices are sub-devices in
    /// A, B order.
    static func compute(
        aOutput: [Int]?,
        bOutput: [Int]?,
        subDeviceInputBuffers: Int,
        aggregateOutput: [Int],
        aggregateInput: [Int]
    ) throws(EngineError) -> AggregateLayout {
        let aChannels = aOutput?.reduce(0, +) ?? 0
        let bChannels = bOutput?.reduce(0, +) ?? 0
        let expectedOutput = aChannels + bChannels
        let actualOutput = aggregateOutput.reduce(0, +)
        guard aOutput != nil || bOutput != nil,
              aOutput == nil || aChannels >= 1, bOutput == nil || bChannels >= 1,
              actualOutput == expectedOutput else {
            throw .layoutMismatch(
                "output channels: sub-devices \(aOutput ?? []) + \(bOutput ?? []), aggregate \(aggregateOutput)")
        }
        let tapBuffers = aggregateInput.count - subDeviceInputBuffers
        guard tapBuffers >= 1 else {
            throw .layoutMismatch(
                "input buffers: \(subDeviceInputBuffers) from sub-devices, aggregate \(aggregateInput), no tap stream")
        }
        return AggregateLayout(
            inFirstBuffer: subDeviceInputBuffers,
            tapBuffers: tapBuffers,
            outAChannelOffset: aOutput == nil ? nil : 0,
            outBChannelOffset: bOutput == nil ? nil : aChannels)
    }
}
