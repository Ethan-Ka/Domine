import Foundation

/// Persistent settings in UserDefaults, all under the "Domine." key prefix.
/// Per-pair tuning is stored as JSON under "Domine.pair.<uidA|uidB>" (see `PairKey`).
/// Globals are plain values, except the exclusion list, which is JSON.
/// Anything missing, corrupt, or of the wrong type reads back as the default.
@MainActor
final class SettingsStore {
    nonisolated static let keyPrefix = "Domine."

    private enum Key: String {
        case lastLeftUID, lastRightUID, lastRearLeftUID, lastRearRightUID, routingMode, lastSurroundUIDs
        case volumeKeysEnabled, restorePreviousOutput, closeBehavior, startWhenBothConnect, reconnectDroppedSpeakers
        case previousOutputUID, outputNeedsRestore, excludedAppsPlayThroughUID, exclusions, appVolumes
        case hasCompletedWelcome, audioCaptureWorking, audioCaptureSignature
        case rooms, currentRoomID

        var name: String { SettingsStore.keyPrefix + rawValue }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Per pair

    nonisolated static func storageKey(for key: PairKey) -> String {
        keyPrefix + "pair." + key.rawValue
    }

    /// Settings for the pair with `leftUID` as Front Left. A pair stored in the
    /// other order is returned flipped; an unknown pair returns defaults.
    func pairSettings(leftUID: String, rightUID: String) -> PairSettings {
        let key = PairKey(leftUID: leftUID, rightUID: rightUID)
        guard let data = defaults.data(forKey: Self.storageKey(for: key)),
              let stored = try? JSONDecoder().decode(PairSettings.self, from: data)
        else { return PairSettings() }
        return key.isSwapped ? stored.swapped : stored
    }

    /// Whether tuning has ever been saved for this pair, in either order.
    func hasPairSettings(leftUID: String, rightUID: String) -> Bool {
        defaults.data(forKey: Self.storageKey(for: PairKey(leftUID: leftUID, rightUID: rightUID))) != nil
    }

    func setPairSettings(_ settings: PairSettings, leftUID: String, rightUID: String) {
        let key = PairKey(leftUID: leftUID, rightUID: rightUID)
        let stored = key.isSwapped ? settings.swapped : settings
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey(for: key))
    }

    func removePairSettings(leftUID: String, rightUID: String) {
        defaults.removeObject(forKey: Self.storageKey(for: PairKey(leftUID: leftUID, rightUID: rightUID)))
    }

    // MARK: Global

    var lastLeftUID: String? {
        get { string(.lastLeftUID) }
        set { set(newValue, .lastLeftUID) }
    }

    var lastRightUID: String? {
        get { string(.lastRightUID) }
        set { set(newValue, .lastRightUID) }
    }

    var lastRearLeftUID: String? {
        get { string(.lastRearLeftUID) }
        set { set(newValue, .lastRearLeftUID) }
    }

    var lastRearRightUID: String? {
        get { string(.lastRearRightUID) }
        set { set(newValue, .lastRearRightUID) }
    }

    /// "stereo" or "surround". Stereo by default. The old "quad" reads as
    /// surround (SPEC 13.7).
    var routingMode: RoutingMode {
        get { string(.routingMode).flatMap(Self.routingMode(stored:)) ?? .stereo }
        set { set(newValue.rawValue, .routingMode) }
    }

    /// A stored routing mode, with quad mapped to surround.
    nonisolated static func routingMode(stored raw: String) -> RoutingMode? {
        raw == "quad" ? .surround : RoutingMode(rawValue: raw)
    }

    // MARK: Surround (SPEC 13.1)

    /// The speakers of the last surround set, in list order
    /// ("Domine.lastSurroundUIDs"). nil when never set.
    var lastSurroundUIDs: [String]? {
        get { defaults.object(forKey: Key.lastSurroundUIDs.name) as? [String] }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.lastSurroundUIDs.name)
            } else {
                defaults.removeObject(forKey: Key.lastSurroundUIDs.name)
            }
        }
    }

    /// The record for a set of speakers in any order; nil when none is saved
    /// or it is corrupt.
    func surroundSettings(uids: [String]) -> SurroundSettings? {
        defaults.data(forKey: SurroundSettings.storageKey(uids: uids))
            .flatMap { try? JSONDecoder().decode(SurroundSettings.self, from: $0) }
    }

    func hasSurroundSettings(uids: [String]) -> Bool {
        defaults.data(forKey: SurroundSettings.storageKey(uids: uids)) != nil
    }

    /// Saved under the key of its own speakers. An empty set is not saved.
    func setSurroundSettings(_ settings: SurroundSettings) {
        guard !settings.speakers.isEmpty, let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: SurroundSettings.storageKey(uids: settings.uids))
    }

    /// SPEC 13.7: every saved quad set (the last one and each room's) gets a
    /// surround record unless one exists for those four UIDs. The last quad
    /// set also becomes the last surround set when there is none. Quad keys
    /// stay in place. Idempotent.
    func migrateQuadSets(rooms: [Room]) {
        let last = [lastLeftUID, lastRightUID, lastRearLeftUID, lastRearRightUID]
        if let set = Self.quadSet(last) {
            migrateQuadSet(set)
            if lastSurroundUIDs == nil { lastSurroundUIDs = set }
        }
        for room in rooms {
            if let set = Self.quadSet([room.leftUID, room.rightUID, room.rearLeftUID, room.rearRightUID]) {
                migrateQuadSet(set)
            }
        }
    }

    private func migrateQuadSet(_ uids: [String]) {
        guard !hasSurroundSettings(uids: uids) else { return }
        let settings = SurroundSettings.migrated(
            frontLeft: uids[0], frontRight: uids[1], rearLeft: uids[2], rearRight: uids[3],
            pair: pairSettings(leftUID: uids[0], rightUID: uids[1]), quad: quadSettings(uids: uids))
        setSurroundSettings(settings)
    }

    /// Four distinct UIDs in position order, or nil.
    nonisolated static func quadSet(_ uids: [String?]) -> [String]? {
        let all = uids.compactMap { $0 }
        return all.count == 4 && Set(all).count == 4 ? all : nil
    }

    /// Quad tuning for a set of four speakers; defaults when unknown or corrupt.
    /// Read only for the migration to surround (SPEC 13.7).
    func quadSettings(uids: [String]) -> QuadSettings {
        defaults.data(forKey: QuadSettings.storageKey(uids: uids))
            .flatMap { try? JSONDecoder().decode(QuadSettings.self, from: $0) } ?? QuadSettings()
    }

    func setQuadSettings(_ settings: QuadSettings, uids: [String]) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: QuadSettings.storageKey(uids: uids))
    }

    /// SPEC section 4b. Off by default.
    var volumeKeysEnabled: Bool {
        get { bool(.volumeKeysEnabled, default: false) }
        set { defaults.set(newValue, forKey: Key.volumeKeysEnabled.name) }
    }

    /// SPEC section 4c. On by default.
    var restorePreviousOutput: Bool {
        get { bool(.restorePreviousOutput, default: true) }
        set { defaults.set(newValue, forKey: Key.restorePreviousOutput.name) }
    }

    /// SPEC section 6a.
    var closeBehavior: CloseBehavior {
        get { string(.closeBehavior).flatMap(CloseBehavior.init(rawValue:)) ?? .keepPlaying }
        set { set(newValue.rawValue, .closeBehavior) }
    }

    /// SPEC section 6a. Off by default.
    var startWhenBothConnect: Bool {
        get { bool(.startWhenBothConnect, default: true) }
        set { defaults.set(newValue, forKey: Key.startWhenBothConnect.name) }
    }

    /// Try to bring a dropped Bluetooth speaker back. On by default.
    var reconnectDroppedSpeakers: Bool {
        get { bool(.reconnectDroppedSpeakers, default: true) }
        set { defaults.set(newValue, forKey: Key.reconnectDroppedSpeakers.name) }
    }

    /// Default output saved at start, for restore on stop and crash recovery (SPEC section 4c).
    var previousOutputUID: String? {
        get { string(.previousOutputUID) }
        set { set(newValue, .previousOutputUID) }
    }

    /// Routing started and the previous output has not been restored yet. Still
    /// true at launch means Domine did not stop cleanly (SPEC section 4c).
    var outputNeedsRestore: Bool {
        get { bool(.outputNeedsRestore, default: false) }
        set { defaults.set(newValue, forKey: Key.outputNeedsRestore.name) }
    }

    /// Where excluded apps play (SPEC section 3b). nil means the previous output.
    var excludedAppsPlayThroughUID: String? {
        get { string(.excludedAppsPlayThroughUID) }
        set { set(newValue, .excludedAppsPlayThroughUID) }
    }

    /// The first-run checklist was dismissed with Continue. Off by default.
    var hasCompletedWelcome: Bool {
        get { bool(.hasCompletedWelcome, default: false) }
        set { defaults.set(newValue, forKey: Key.hasCompletedWelcome.name) }
    }

    /// Non-zero audio arrived from a process tap at least once, so audio
    /// capture permission was granted (SPEC section 8). Off by default.
    var audioCaptureWorking: Bool {
        get { bool(.audioCaptureWorking, default: false) }
        set { defaults.set(newValue, forKey: Key.audioCaptureWorking.name) }
    }

    /// The code signature `audioCaptureWorking` was recorded under. A grant
    /// belongs to one signature, so a different one makes the flag stale.
    var audioCaptureSignature: String? {
        get { string(.audioCaptureSignature) }
        set { set(newValue, .audioCaptureSignature) }
    }

    /// Saved rooms. Missing or corrupt reads as none.
    var rooms: [Room] {
        get {
            defaults.data(forKey: Key.rooms.name)
                .flatMap { try? JSONDecoder().decode([Room].self, from: $0) } ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.rooms.name)
        }
    }

    var currentRoomID: UUID? {
        get { string(.currentRoomID).flatMap(UUID.init(uuidString:)) }
        set { set(newValue?.uuidString, .currentRoomID) }
    }

    /// Entries that fail to decode are dropped; the rest are kept.
    var exclusions: [AppExclusion] {
        get {
            guard let data = defaults.data(forKey: Key.exclusions.name),
                  let entries = try? JSONDecoder().decode([LossyExclusion].self, from: data)
            else { return [] }
            return entries.compactMap(\.value)
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.exclusions.name)
        }
    }

    /// Per-app volume by bundle ID, 0...1. A missing app plays at 1.
    var appVolumes: [String: Double] {
        get {
            let raw = defaults.dictionary(forKey: Key.appVolumes.name) ?? [:]
            return raw.compactMapValues { ($0 as? Double).map { min(max($0, 0), 1) } }
        }
        set { defaults.set(newValue, forKey: Key.appVolumes.name) }
    }

    // MARK: Helpers

    private func string(_ key: Key) -> String? {
        defaults.object(forKey: key.name) as? String
    }

    private func bool(_ key: Key, default fallback: Bool) -> Bool {
        (defaults.object(forKey: key.name) as? Bool) ?? fallback
    }

    private func set(_ value: String?, _ key: Key) {
        if let value {
            defaults.set(value, forKey: key.name)
        } else {
            defaults.removeObject(forKey: key.name)
        }
    }
}

/// Decodes one list element without failing the whole array.
private struct LossyExclusion: Decodable {
    let value: AppExclusion?

    init(from decoder: any Decoder) throws {
        value = try? AppExclusion(from: decoder)
    }
}
