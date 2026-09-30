import Foundation

/// Persistent settings in UserDefaults, all under the "Domine." key prefix.
/// Per-pair tuning is stored as JSON under "Domine.pair.<uidA|uidB>" (see `PairKey`).
/// Globals are plain values, except the exclusion list, which is JSON.
/// Anything missing, corrupt, or of the wrong type reads back as the default.
@MainActor
final class SettingsStore {
    nonisolated static let keyPrefix = "Domine."

    private enum Key: String {
        case lastLeftUID, lastRightUID
        case volumeKeysEnabled, restorePreviousOutput, closeBehavior, startWhenBothConnect
        case previousOutputUID, excludedAppsPlayThroughUID, exclusions

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
        get { bool(.startWhenBothConnect, default: false) }
        set { defaults.set(newValue, forKey: Key.startWhenBothConnect.name) }
    }

    /// Default output saved at start, for restore on stop and crash recovery (SPEC section 4c).
    var previousOutputUID: String? {
        get { string(.previousOutputUID) }
        set { set(newValue, .previousOutputUID) }
    }

    /// Where excluded apps play (SPEC section 3b). nil means the previous output.
    var excludedAppsPlayThroughUID: String? {
        get { string(.excludedAppsPlayThroughUID) }
        set { set(newValue, .excludedAppsPlayThroughUID) }
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
