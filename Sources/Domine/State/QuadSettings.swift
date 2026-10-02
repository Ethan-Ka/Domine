import Foundation

/// Tuning for one set of four speakers (SPEC 11.7). Stored under
/// "Domine.quad.<four UIDs, sorted, joined by |>", so any arrangement of the
/// same four speakers finds the same record.
struct QuadSettings: Codable, Equatable, Sendable {
    /// Rear level relative to the fronts, 0...1.
    var rearTrim: Float = 1

    static func storageKey(uids: [String]) -> String {
        SettingsStore.keyPrefix + "quad." + uids.sorted().joined(separator: "|")
    }
}
