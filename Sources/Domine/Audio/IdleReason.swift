/// Why a start request left the engine idle.
enum IdleReason: Equatable, Sendable {
    case noLeftSpeaker
    case noRightSpeaker
    case leftMissing
    case rightMissing
    case sameSpeaker
    /// Routing stopped because both speakers disconnected.
    case speakersDisconnected
    /// Surround start with an empty set.
    case noSurroundSpeakers
    /// Surround start with no speaker of the set connected.
    case surroundMissing

    var description: String {
        switch self {
        case .noLeftSpeaker: "Choose a left speaker"
        case .noRightSpeaker: "Choose a right speaker"
        case .leftMissing: "Left speaker is not connected"
        case .rightMissing: "Right speaker is not connected"
        case .sameSpeaker: "Left and right must be different speakers"
        case .speakersDisconnected: "Both speakers disconnected"
        case .noSurroundSpeakers: "Add surround speakers"
        case .surroundMissing: "Surround speakers are not connected"
        }
    }
}
