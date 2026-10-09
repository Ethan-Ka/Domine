/// Tuning for one pair of speakers, always expressed from the point of view
/// of the current assignment: `left` is whatever device is Front Left now.
/// `SettingsStore` handles the flip when the same pair is stored the other way round.
struct PairSettings: Codable, Equatable, Sendable {
    static let delayLimitMs: Float = 300

    /// Signed offset in ms (SPEC section 4). Positive delays the right speaker,
    /// negative delays the left. Clamped to -300...300.
    var delayMs: Float = 0
    /// Slider shows -300...300 ms instead of -50...50 ms.
    var extendedRange = false
    /// Tuning sheet Balance slider, -1...1. 0 is centered, -1 is full left, 1 is full right.
    var balance: Float = 0
    /// Hardware volume applied to both speakers (SPEC section 4a), 0...1.
    var masterVolume: Float = 0.5
    /// EQ, bass, and compressor, per speaker or linked.
    var effects = EffectsSettings()
    /// Stereo only: how much of each side is mixed into the other, 0...1.
    var crossfeed: Double = 0
    /// Both speakers play the same mix (speakers in different rooms).
    var sameOnBoth = false
    /// Hardware volume offset of each speaker in dB, -12...12 (SPEC 4a):
    /// how far that speaker sits above or below the master volume.
    var leftVolumeOffsetDb: Float = 0
    var rightVolumeOffsetDb: Float = 0

    /// What the kernel gets: full mix while `sameOnBoth`, else the slider.
    var effectiveCrossfeed: Float { sameOnBoth ? 1 : Float(min(max(crossfeed.isFinite ? crossfeed : 0, 0), 1)) }

    init(delayMs: Float = 0, extendedRange: Bool = false, balance: Float = 0, masterVolume: Float = 0.5,
         effects: EffectsSettings = EffectsSettings(),
         crossfeed: Double = 0, sameOnBoth: Bool = false,
         leftVolumeOffsetDb: Float = 0, rightVolumeOffsetDb: Float = 0) {
        self.leftVolumeOffsetDb = leftVolumeOffsetDb
        self.rightVolumeOffsetDb = rightVolumeOffsetDb
        self.crossfeed = crossfeed
        self.sameOnBoth = sameOnBoth
        self.effects = effects
        self.delayMs = delayMs
        self.extendedRange = extendedRange
        self.balance = balance
        self.masterVolume = masterVolume
        sanitize()
    }

    /// Kernel gain for the left speaker. Balance only ever attenuates the far side:
    /// moving right (balance > 0) lowers the left gain linearly to 0 at balance 1,
    /// and the right gain stays at 1.0. Balance 0 gives 1.0 on both sides.
    var leftGain: Float { balance > 0 ? 1 - balance : 1 }

    /// Kernel gain for the right speaker. Mirror of `leftGain`.
    var rightGain: Float { balance < 0 ? 1 + balance : 1 }

    /// The same physical tuning seen with Front Left and Front Right swapped:
    /// the same speaker stays delayed and the same speaker stays attenuated.
    var swapped: PairSettings {
        var copy = self
        copy.delayMs = delayMs == 0 ? 0 : -delayMs
        copy.balance = balance == 0 ? 0 : -balance
        copy.effects = effects.swapped
        copy.leftVolumeOffsetDb = rightVolumeOffsetDb
        copy.rightVolumeOffsetDb = leftVolumeOffsetDb
        return copy
    }

    private mutating func sanitize() {
        delayMs = Self.clamp(delayMs, -Self.delayLimitMs, Self.delayLimitMs, fallback: 0)
        balance = Self.clamp(balance, -1, 1, fallback: 0)
        masterVolume = Self.clamp(masterVolume, 0, 1, fallback: 0.5)
        let offsets = SpeakerVolumeLink.offsetRange
        leftVolumeOffsetDb = Self.clamp(leftVolumeOffsetDb, offsets.lowerBound, offsets.upperBound, fallback: 0)
        rightVolumeOffsetDb = Self.clamp(rightVolumeOffsetDb, offsets.lowerBound, offsets.upperBound, fallback: 0)
    }

    private static func clamp(_ value: Float, _ low: Float, _ high: Float, fallback: Float) -> Float {
        value.isFinite ? min(max(value, low), high) : fallback
    }

    private enum CodingKeys: String, CodingKey {
        case delayMs, extendedRange, balance, masterVolume, effects, crossfeed, sameOnBoth
        case leftVolumeOffsetDb, rightVolumeOffsetDb
    }

    /// Missing or mistyped fields fall back to their defaults one by one,
    /// so adding a field later does not throw away a user's stored tuning.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PairSettings()
        self.init(
            delayMs: (try? c.decodeIfPresent(Float.self, forKey: .delayMs)) ?? defaults.delayMs,
            extendedRange: (try? c.decodeIfPresent(Bool.self, forKey: .extendedRange)) ?? defaults.extendedRange,
            balance: (try? c.decodeIfPresent(Float.self, forKey: .balance)) ?? defaults.balance,
            masterVolume: (try? c.decodeIfPresent(Float.self, forKey: .masterVolume)) ?? defaults.masterVolume,
            effects: (try? c.decodeIfPresent(EffectsSettings.self, forKey: .effects)) ?? defaults.effects,
            crossfeed: (try? c.decodeIfPresent(Double.self, forKey: .crossfeed)) ?? defaults.crossfeed,
            sameOnBoth: (try? c.decodeIfPresent(Bool.self, forKey: .sameOnBoth)) ?? defaults.sameOnBoth,
            leftVolumeOffsetDb: (try? c.decodeIfPresent(Float.self, forKey: .leftVolumeOffsetDb)) ?? 0,
            rightVolumeOffsetDb: (try? c.decodeIfPresent(Float.self, forKey: .rightVolumeOffsetDb)) ?? 0)
    }
}
