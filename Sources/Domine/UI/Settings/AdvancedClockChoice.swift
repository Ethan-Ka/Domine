/// One speaker in the Timing reference picker.
struct AdvancedClockChoice: Identifiable, Equatable, Sendable {
    var uid: String
    /// Position, name and UID suffix, never the name alone.
    var name: String
    /// False for a saved speaker that is not connected or not in this mode.
    var isAvailable = true

    var id: String { uid }

    var title: String { isAvailable ? name : "\(name) (not in use)" }
}
