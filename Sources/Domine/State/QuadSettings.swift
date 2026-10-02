import Foundation

/// Tuning for one set of four speakers (SPEC 11.7). Stored under
/// "Domine.quad.<four UIDs, sorted, joined by |>", so any arrangement of the
/// same four speakers finds the same record.
struct QuadSettings: Codable, Equatable, Sendable {
    /// Rear level relative to the fronts, 0...1.
    var rearTrim: Float = 1
    /// DOMINE_REAR_MIRROR (0) or DOMINE_REAR_MATRIX (1).
    var rearMode: Int = 0

    /// While on, the rears use the front speakers' effects.
    var linkRears = true
    var rearLeft = PairSettings.SideEffects()
    var rearRight = PairSettings.SideEffects()

    init() {}

    /// The effects the two rears actually get, given the fronts' effects.
    /// `linkSpeakers` makes the rear right follow the rear left.
    func rearEffects(frontLeft: PairSettings.SideEffects, frontRight: PairSettings.SideEffects,
                     linkSpeakers: Bool) -> (left: PairSettings.SideEffects, right: PairSettings.SideEffects) {
        if linkRears { return (frontLeft, frontRight) }
        return (rearLeft, linkSpeakers ? rearLeft : rearRight)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rearTrim = try c.decodeIfPresent(Float.self, forKey: .rearTrim) ?? 1
        rearMode = try c.decodeIfPresent(Int.self, forKey: .rearMode) ?? 0
        linkRears = (try? c.decodeIfPresent(Bool.self, forKey: .linkRears)) ?? true
        rearLeft = (try? c.decodeIfPresent(PairSettings.SideEffects.self, forKey: .rearLeft)) ?? PairSettings.SideEffects()
        rearRight = (try? c.decodeIfPresent(PairSettings.SideEffects.self, forKey: .rearRight)) ?? PairSettings.SideEffects()
    }

    private enum CodingKeys: String, CodingKey { case rearTrim, rearMode, linkRears, rearLeft, rearRight }

    static func storageKey(uids: [String]) -> String {
        SettingsStore.keyPrefix + "quad." + uids.sorted().joined(separator: "|")
    }
}
