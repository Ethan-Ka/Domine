/// One speaker line in the menu bar panel.
struct StatusMenuSpeaker: Equatable, Sendable {
    /// "Front Left" or "Front Right".
    var position: String
    /// Device name plus UID suffix, e.g. "JBL Grip · 4F2A". Never the name alone.
    var deviceLabel: String
    var isConnected: Bool
}
