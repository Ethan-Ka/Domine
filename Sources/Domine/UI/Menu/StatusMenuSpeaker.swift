/// One speaker line in the menu bar panel.
struct StatusMenuSpeaker: Equatable, Sendable {
    /// "Front Left" or "Front Right".
    var position: String
    var deviceName: String
    /// Shown beside the name, since both Grips are called "JBL Grip".
    var uidSuffix: String
    var isConnected: Bool
}
