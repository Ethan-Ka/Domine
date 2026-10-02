import Foundation

/// Tuning for one set of four speakers (SPEC 11.7). Stored under
/// "Domine.quad.<four UIDs, sorted, joined by |>", so any arrangement of the
/// same four speakers finds the same record.
struct QuadSettings: Codable, Equatable, Sendable {
    /// Rear level relative to the fronts, 0...1.
    var rearTrim: Float = 1
    /// DOMINE_REAR_MIRROR (0) or DOMINE_REAR_MATRIX (1).
    var rearMode: Int = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rearTrim = try c.decodeIfPresent(Float.self, forKey: .rearTrim) ?? 1
        rearMode = try c.decodeIfPresent(Int.self, forKey: .rearMode) ?? 0
    }

    static func storageKey(uids: [String]) -> String {
        SettingsStore.keyPrefix + "quad." + uids.sorted().joined(separator: "|")
    }
}
