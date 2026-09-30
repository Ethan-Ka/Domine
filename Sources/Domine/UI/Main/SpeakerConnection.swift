/// How a stage position is drawn.
enum SpeakerConnection: Equatable, Sendable {
    /// A device is assigned and playing (or ready to play).
    case connected
    /// A device is assigned but gone or not responding.
    case disconnected
    /// Not available in this mode (rear positions in stereo).
    case placeholder
    /// Available, but no device chosen yet.
    case unassigned
}
