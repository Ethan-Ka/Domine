/// Output latency a device reports to Core Audio, in frames (SPEC section 4a).
/// Bluetooth devices often report these inaccurately; the delay slider wins.
struct DeviceLatency: Equatable, Sendable {
    /// `kAudioDevicePropertyLatency`, output scope.
    var deviceFrames: UInt32 = 0
    /// `kAudioDevicePropertySafetyOffset`, output scope.
    var safetyOffsetFrames: UInt32 = 0
    /// Largest `kAudioStreamPropertyLatency` among the device's output streams.
    var streamFrames: UInt32 = 0

    var totalFrames: UInt64 {
        UInt64(deviceFrames) + UInt64(safetyOffsetFrames) + UInt64(streamFrames)
    }

    /// Total latency in milliseconds at `sampleRate`, or nil for a rate that is not positive.
    func milliseconds(sampleRate: Double) -> Double? {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        return Double(totalFrames) * 1000 / sampleRate
    }
}
