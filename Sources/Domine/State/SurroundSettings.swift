import Foundation

/// Tuning for one set of surround speakers (SPEC 13.1). Stored under
/// "Domine.surround.<UIDs sorted, joined by |>", so any order of the same
/// speakers finds the same record. `speakers` keeps the list order, which is
/// the speaker index everywhere (kernel, aggregate, cards).
struct SurroundSettings: Codable, Equatable, Sendable {
    typealias Effects = PairSettings.SideEffects

    static let widthRange: ClosedRange<Float> = 10...90
    /// The kernel clamps to +-720; the UI offers -90...90.
    static let orbitRange: ClosedRange<Float> = -720...720

    var speakers: [SurroundSpeaker] = []
    /// Azimuth of the L and R sources, 10...90 degrees.
    var width: Float = 30
    /// Surround level, 0...2 (above 1 adds rear fill).
    var surroundLevel: Float = 0.7
    /// Degrees per second, 0 is off.
    var orbitRate: Float = 0
    /// Static rotation of the field, degrees.
    var rotation: Float = 0
    /// Spatial upmixer: ambience amount 0...1 and room size 5...30 ms.
    var spatialAmount: Float = 0.6
    var spatialRoomMs: Float = 15
    /// Per speaker by UID: trim gain 0...1 (missing is 1), calibration offset
    /// in ms (missing is 0), and effects (missing is the default).
    var trims: [String: Float] = [:]
    var offsetsMs: [String: Float] = [:]
    var effects: [String: Effects] = [:]
    /// Per speaker by UID: hardware volume offset in dB, -12...12 (SPEC 4a).
    /// Missing is 0.
    var volumeOffsetsDb: [String: Float] = [:]
    /// While on, every speaker uses the first speaker's effects.
    var linkEffects = true
    /// L and R summed before panning, so every speaker plays the whole mix.
    var mono = false
    /// The offsets were measured with the microphone (SPEC 12, 13.4): they
    /// hold the whole arrival difference, so distance sets level only.
    /// Manual offset edits keep it; Reset and a change of speakers clear it.
    var timingMeasured = false

    init() {}

    /// A fresh record for `uids` in that order, each at its default azimuth.
    init(uids: [String]) {
        speakers = Self.unique(uids).enumerated().map { index, uid in
            SurroundSpeaker(uid: uid, azimuth: SurroundSpeaker.defaultAzimuth(forIndex: index))
        }
    }

    var uids: [String] { speakers.map(\.uid) }

    func trim(for uid: String) -> Float { trims[uid] ?? 1 }
    func offsetMs(for uid: String) -> Float { offsetsMs[uid] ?? 0 }
    func volumeOffsetDb(for uid: String) -> Float { volumeOffsetsDb[uid] ?? 0 }

    /// The effects a speaker plays with: the first speaker's while linked.
    func resolvedEffects(for uid: String) -> Effects {
        let source = linkEffects ? (speakers.first?.uid ?? uid) : uid
        return effects[source] ?? Effects()
    }

    /// This record for a new list of speakers (SPEC 13.1): speakers that stay
    /// keep everything, a new one gets the default azimuth for its index and
    /// 2 m. Per-speaker values of speakers that left are dropped.
    func carried(to newUIDs: [String]) -> SurroundSettings {
        var copy = self
        copy.speakers = Self.unique(newUIDs).enumerated().map { index, uid in
            speakers.first { $0.uid == uid }
                ?? SurroundSpeaker(uid: uid, azimuth: SurroundSpeaker.defaultAzimuth(forIndex: index))
        }
        let kept = Set(copy.uids)
        copy.trims = trims.filter { kept.contains($0.key) }
        copy.offsetsMs = offsetsMs.filter { kept.contains($0.key) }
        copy.effects = effects.filter { kept.contains($0.key) }
        copy.volumeOffsetsDb = volumeOffsetsDb.filter { kept.contains($0.key) }
        // A different set needs its timing measured again.
        if kept != Set(uids) { copy.timingMeasured = false }
        return copy
    }

    /// Clamps and wraps every value into range; drops duplicate speakers and
    /// anything past `SurroundSpeaker.maxCount`.
    mutating func sanitize() {
        var seen = Set<String>()
        speakers = speakers.filter { seen.insert($0.uid).inserted }
        if speakers.count > SurroundSpeaker.maxCount { speakers = Array(speakers.prefix(SurroundSpeaker.maxCount)) }
        for index in speakers.indices {
            speakers[index].azimuth = SurroundSpeaker.wrap(speakers[index].azimuth)
            speakers[index].distance = Self.clamp(speakers[index].distance, SurroundSpeaker.distanceRange, fallback: 2)
        }
        width = Self.clamp(width, Self.widthRange, fallback: 30)
        surroundLevel = Self.clamp(surroundLevel, 0...2, fallback: 0.7)
        orbitRate = Self.clamp(orbitRate, Self.orbitRange, fallback: 0)
        rotation = SurroundSpeaker.wrap(rotation)
        spatialAmount = Self.clamp(spatialAmount, 0...1, fallback: 0.6)
        spatialRoomMs = Self.clamp(spatialRoomMs, 5...30, fallback: 15)
        trims = trims.mapValues { Self.clamp($0, 0...1, fallback: 1) }
        offsetsMs = offsetsMs.mapValues { Self.clamp($0, 0...PairSettings.delayLimitMs, fallback: 0) }
        volumeOffsetsDb = volumeOffsetsDb.mapValues { Self.clamp($0, SpeakerVolumeLink.offsetRange, fallback: 0) }
            .filter { $0.value != 0 }
    }

    static func clamp(_ value: Float, _ range: ClosedRange<Float>, fallback: Float) -> Float {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    static func storageKey(uids: [String]) -> String {
        SettingsStore.keyPrefix + "surround." + uids.sorted().joined(separator: "|")
    }

    private static func unique(_ uids: [String]) -> [String] {
        var seen = Set<String>()
        return Array(uids.filter { seen.insert($0).inserted }.prefix(SurroundSpeaker.maxCount))
    }

    // MARK: Quad migration (SPEC 13.7)

    /// The surround record for a saved quad set: FL -30, FR 30, RL -110,
    /// RR 110 at 2 m. Fronts take the pair's effects, trims (balance) and the
    /// signed delay as two non-negative offsets; rears take
    /// `QuadSettings.rearEffects`. Rear trim becomes surround level; Mirror
    /// becomes spatial amount 0, Matrix the default 0.6.
    static func migrated(frontLeft: String, frontRight: String, rearLeft: String, rearRight: String,
                         pair: PairSettings, quad: QuadSettings) -> SurroundSettings {
        var s = SurroundSettings()
        let uids = [frontLeft, frontRight, rearLeft, rearRight]
        s.speakers = zip(uids, [Float(-30), 30, -110, 110]).map { SurroundSpeaker(uid: $0, azimuth: $1) }
        let fronts = (pair.effects.left, pair.effects.effectiveRight)
        let rears = quad.rearEffects(frontLeft: fronts.0, frontRight: fronts.1, linkSpeakers: pair.effects.linkSpeakers)
        s.effects = [frontLeft: fronts.0, frontRight: fronts.1, rearLeft: rears.left, rearRight: rears.right]
        // Linked only when every speaker already plays the same effects.
        s.linkEffects = uids.allSatisfy { s.effects[$0] == fronts.0 }
        if pair.leftGain != 1 { s.trims[frontLeft] = pair.leftGain }
        if pair.rightGain != 1 { s.trims[frontRight] = pair.rightGain }
        if pair.delayMs < 0 { s.offsetsMs[frontLeft] = -pair.delayMs }
        if pair.delayMs > 0 { s.offsetsMs[frontRight] = pair.delayMs }
        s.surroundLevel = quad.rearTrim
        s.spatialRoomMs = quad.spatialRoomMs
        switch quad.rearMode {
        case 1: s.spatialAmount = 0.6  // Matrix has no equivalent.
        case 3: s.spatialAmount = quad.spatialAmount  // Spatial.
        default: s.spatialAmount = 0  // Mirror (and Direct, which played as mirror).
        }
        s.sanitize()
        return s
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case speakers, width, surroundLevel, orbitRate, rotation, spatialAmount, spatialRoomMs
        case trims, offsetsMs, effects, linkEffects, timingMeasured, mono, volumeOffsetsDb
    }

    /// Missing or mistyped fields fall back to their defaults one by one; a
    /// bad speaker entry is dropped without losing the rest.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SurroundSettings()
        let entries = (try? c.decodeIfPresent([LossySpeaker].self, forKey: .speakers)) ?? []
        speakers = entries.compactMap(\.value)
        width = (try? c.decodeIfPresent(Float.self, forKey: .width)) ?? d.width
        surroundLevel = (try? c.decodeIfPresent(Float.self, forKey: .surroundLevel)) ?? d.surroundLevel
        orbitRate = (try? c.decodeIfPresent(Float.self, forKey: .orbitRate)) ?? d.orbitRate
        rotation = (try? c.decodeIfPresent(Float.self, forKey: .rotation)) ?? d.rotation
        spatialAmount = (try? c.decodeIfPresent(Float.self, forKey: .spatialAmount)) ?? d.spatialAmount
        spatialRoomMs = (try? c.decodeIfPresent(Float.self, forKey: .spatialRoomMs)) ?? d.spatialRoomMs
        trims = (try? c.decodeIfPresent([String: Float].self, forKey: .trims)) ?? [:]
        offsetsMs = (try? c.decodeIfPresent([String: Float].self, forKey: .offsetsMs)) ?? [:]
        effects = (try? c.decodeIfPresent([String: Effects].self, forKey: .effects)) ?? [:]
        volumeOffsetsDb = (try? c.decodeIfPresent([String: Float].self, forKey: .volumeOffsetsDb)) ?? [:]
        linkEffects = (try? c.decodeIfPresent(Bool.self, forKey: .linkEffects)) ?? d.linkEffects
        timingMeasured = (try? c.decodeIfPresent(Bool.self, forKey: .timingMeasured)) ?? d.timingMeasured
        mono = (try? c.decodeIfPresent(Bool.self, forKey: .mono)) ?? d.mono
        sanitize()
    }

    private struct LossySpeaker: Decodable {
        let value: SurroundSpeaker?
        init(from decoder: any Decoder) throws { value = try? SurroundSpeaker(from: decoder) }
    }
}
