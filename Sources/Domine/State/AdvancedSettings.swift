import Foundation

/// Settings > Advanced (docs/IDEAS.md customizability 4, 5, 8, 9, 13).
/// Defaults are the values Domine used before these were settings. Every
/// value is clamped to its range when set through `init` or decoded, so a
/// corrupt or hand-edited store reads back in range.
struct AdvancedSettings: Codable, Equatable, Sendable {
    // MARK: Keep-alive

    static let keepAliveIdleRange: ClosedRange<Double> = 0.5...10
    static let keepAliveHzRange: ClosedRange<Double> = 10...40
    static let keepAliveLevelRange: ClosedRange<Double> = -70...(-40)

    /// Seconds of silence before the keep-alive tone starts.
    var keepAliveIdleSeconds: Double = 2
    var keepAliveHz: Double = 15
    /// Tone peak level, dBFS.
    var keepAliveLevelDb: Double = -60

    /// Linear peak amplitude for the kernel. -60 dBFS is exactly 1e-3, the
    /// kernel's default, so the default setting changes nothing.
    var keepAliveAmplitude: Double {
        keepAliveLevelDb == -60 ? 1.0e-3 : pow(10, keepAliveLevelDb / 20)
    }

    // MARK: Clock

    /// The speaker that clocks the aggregate, by UID. Nil is the first
    /// speaker of the route.
    var clockSpeakerUID: String?

    // MARK: Limits

    static let maxVolumeRange: ClosedRange<Double> = 1...Double(PairSettings.maxMasterVolume)
    static let offsetRangeChoices: [Double] = [6, 12]

    /// Highest master volume in Single and Stereo; above 1 is the boost.
    var maxVolume = Double(PairSettings.maxMasterVolume)
    /// Per-speaker volume offsets go from minus to plus this many dB.
    var offsetRangeDb: Double = 12

    // MARK: Calibration

    static let calibrationSecondsRange: ClosedRange<Double> = 4...12
    static let calibrationAttemptsRange: ClosedRange<Int> = 0...5
    static let calibrationStartVolumeRange: ClosedRange<Double> = 0.5...1

    var calibrationRecordSeconds: Double = 5.5
    var calibrationExtraAttempts = 3
    /// Chirp gain of the first recording, 0.5...1.
    var calibrationStartVolume: Double = 1

    // MARK: Reconnect and HUD

    static let reconnectFirstDelayRange: ClosedRange<Double> = 2...30
    static let reconnectRetryRange: ClosedRange<Double> = 10...120
    static let reconnectGiveUpRange: ClosedRange<Double> = 1...60
    static let hudSecondsRange: ClosedRange<Double> = 0.5...4

    var reconnectFirstDelaySeconds: Double = 5
    var reconnectRetrySeconds: Double = 30
    var reconnectGiveUpMinutes: Double = 10
    var showsVolumeHUD = true
    var volumeHUDSeconds: Double = 1.5

    var reconnectTiming: ReconnectTiming {
        ReconnectTiming(
            firstDelay: .milliseconds(Int((reconnectFirstDelaySeconds * 1000).rounded())),
            retryDelay: .milliseconds(Int((reconnectRetrySeconds * 1000).rounded())),
            giveUpAfter: .seconds(Int((reconnectGiveUpMinutes * 60).rounded())))
    }

    init() {}

    /// Every value in range; out-of-range values clamp, non-finite ones take the default.
    func sanitized() -> AdvancedSettings {
        let d = AdvancedSettings()
        var s = self
        s.keepAliveIdleSeconds = Self.clamp(keepAliveIdleSeconds, Self.keepAliveIdleRange, d.keepAliveIdleSeconds)
        s.keepAliveHz = Self.clamp(keepAliveHz, Self.keepAliveHzRange, d.keepAliveHz)
        s.keepAliveLevelDb = Self.clamp(keepAliveLevelDb, Self.keepAliveLevelRange, d.keepAliveLevelDb)
        if s.clockSpeakerUID?.isEmpty == true { s.clockSpeakerUID = nil }
        s.maxVolume = Self.clamp(maxVolume, Self.maxVolumeRange, d.maxVolume)
        s.offsetRangeDb = offsetRangeDb.isFinite
            ? Self.offsetRangeChoices.min { abs($0 - offsetRangeDb) < abs($1 - offsetRangeDb) } ?? d.offsetRangeDb
            : d.offsetRangeDb
        s.calibrationRecordSeconds = Self.clamp(calibrationRecordSeconds, Self.calibrationSecondsRange,
                                                d.calibrationRecordSeconds)
        s.calibrationExtraAttempts = min(max(calibrationExtraAttempts, Self.calibrationAttemptsRange.lowerBound),
                                         Self.calibrationAttemptsRange.upperBound)
        s.calibrationStartVolume = Self.clamp(calibrationStartVolume, Self.calibrationStartVolumeRange,
                                              d.calibrationStartVolume)
        s.reconnectFirstDelaySeconds = Self.clamp(reconnectFirstDelaySeconds, Self.reconnectFirstDelayRange,
                                                  d.reconnectFirstDelaySeconds)
        s.reconnectRetrySeconds = Self.clamp(reconnectRetrySeconds, Self.reconnectRetryRange, d.reconnectRetrySeconds)
        s.reconnectGiveUpMinutes = Self.clamp(reconnectGiveUpMinutes, Self.reconnectGiveUpRange,
                                              d.reconnectGiveUpMinutes)
        s.volumeHUDSeconds = Self.clamp(volumeHUDSeconds, Self.hudSecondsRange, d.volumeHUDSeconds)
        return s
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case keepAliveIdleSeconds, keepAliveHz, keepAliveLevelDb, clockSpeakerUID, maxVolume, offsetRangeDb
        case calibrationRecordSeconds, calibrationExtraAttempts, calibrationStartVolume
        case reconnectFirstDelaySeconds, reconnectRetrySeconds, reconnectGiveUpMinutes
        case showsVolumeHUD, volumeHUDSeconds
    }

    /// Missing or mistyped keys read as their default; the rest are kept.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = AdvancedSettings()
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { value = v }
        }
        read(.keepAliveIdleSeconds, &s.keepAliveIdleSeconds)
        read(.keepAliveHz, &s.keepAliveHz)
        read(.keepAliveLevelDb, &s.keepAliveLevelDb)
        s.clockSpeakerUID = try? c.decodeIfPresent(String.self, forKey: .clockSpeakerUID)
        read(.maxVolume, &s.maxVolume)
        read(.offsetRangeDb, &s.offsetRangeDb)
        read(.calibrationRecordSeconds, &s.calibrationRecordSeconds)
        read(.calibrationExtraAttempts, &s.calibrationExtraAttempts)
        read(.calibrationStartVolume, &s.calibrationStartVolume)
        read(.reconnectFirstDelaySeconds, &s.reconnectFirstDelaySeconds)
        read(.reconnectRetrySeconds, &s.reconnectRetrySeconds)
        read(.reconnectGiveUpMinutes, &s.reconnectGiveUpMinutes)
        read(.showsVolumeHUD, &s.showsVolumeHUD)
        read(.volumeHUDSeconds, &s.volumeHUDSeconds)
        self = s.sanitized()
    }
}
