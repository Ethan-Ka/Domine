import Foundation

/// A named, saved speaker setup. It stores the mode and the speaker UIDs only.
/// Delay, balance, effects, and quad rear settings already live in the
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
}
