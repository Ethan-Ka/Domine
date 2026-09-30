/// One output in the Choose Speaker sheet.
struct AssignRow: Identifiable, Equatable, Sendable {
    var uid: String
    var name: String
    /// UID suffix like "4F2A", or "Built-in".
    var suffix: String
    /// Status pieces, each drawn as its own text, e.g. ["Bluetooth", "AAC"]
    /// or ["In use as Front Right"].
    var details: [String]
    var isSelected: Bool

    var id: String { uid }
}
