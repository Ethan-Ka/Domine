import Foundation

/// A named, saved speaker setup. It stores the mode and the speaker UIDs only.
/// Delay, balance, effects, and surround settings already live in the
/// per-pair and per-set records keyed by those UIDs, so selecting a room
/// brings them back with it.
struct Room: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var mode: RoutingMode
    var leftUID: String?
    var rightUID: String?
    var rearLeftUID: String?
    var rearRightUID: String?
    /// The surround set in list order (SPEC 13). nil in rooms saved before it.
    var surroundUIDs: [String]?
}

extension Room {
    private enum CodingKeys: String, CodingKey {
        case id, name, mode, leftUID, rightUID, rearLeftUID, rearRightUID, surroundUIDs
    }

    /// A stored "quad" mode reads as surround, and a quad room without a
    /// surround set gets its four speakers as one (SPEC 13.7).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let rawMode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil
        mode = rawMode.flatMap(SettingsStore.routingMode(stored:)) ?? .stereo
        leftUID = (try? c.decodeIfPresent(String.self, forKey: .leftUID)) ?? nil
        rightUID = (try? c.decodeIfPresent(String.self, forKey: .rightUID)) ?? nil
        rearLeftUID = (try? c.decodeIfPresent(String.self, forKey: .rearLeftUID)) ?? nil
        rearRightUID = (try? c.decodeIfPresent(String.self, forKey: .rearRightUID)) ?? nil
        surroundUIDs = ((try? c.decodeIfPresent([String].self, forKey: .surroundUIDs)) ?? nil)
            ?? SettingsStore.quadSet([leftUID, rightUID, rearLeftUID, rearRightUID])
    }
}
