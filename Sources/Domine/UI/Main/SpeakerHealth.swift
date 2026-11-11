/// How well a speaker has kept up this session (docs/IDEAS.md, visual 2).
/// Fed by the engine's dropout tracker; cleared by Reset Counts and by a
/// new session.
enum SpeakerHealth: Equatable, Sendable {
    case ok
    /// Overloads plus disconnects since the session started.
    case dropouts(Int)

    init(_ entry: DropoutCounts.Entry) {
        let total = entry.overloads + entry.disconnects
        self = total > 0 ? .dropouts(total) : .ok
    }

    /// The card's detail line, or nil when healthy.
    var text: String? {
        switch self {
        case .ok: nil
        case .dropouts(1): "Dropped out once"
        case .dropouts(let count): "Dropped out \(count) times"
        }
    }
}
