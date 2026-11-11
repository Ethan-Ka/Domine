/// One speaker's role picker in Sync & Balance.
struct SpeakerRoleRow: Identifiable, Equatable, Sendable {
    /// Device UID.
    var uid: String
    /// "Left", "Right", or a surround direction like "Front Left".
    var title: String
    /// Four characters from the UID that tell two "JBL Grip"s apart.
    var suffix: String?
    var role: SpeakerRole = .fullRange

    var id: String { uid }

    var label: String { [title, suffix].compactMap { $0 }.joined(separator: " ") }
}
