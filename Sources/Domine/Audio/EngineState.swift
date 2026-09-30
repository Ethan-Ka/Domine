/// Engine lifecycle (SPEC section 7). M4 adds `degraded(reason)`.
enum EngineState: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopping
    case error(String)

    /// Starting or running: the UI shows the engine as on.
    var isActive: Bool {
        switch self {
        case .starting, .running: true
        case .idle, .stopping, .error: false
        }
    }
}
