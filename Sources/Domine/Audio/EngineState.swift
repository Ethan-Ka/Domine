/// Engine lifecycle (SPEC section 7).
enum EngineState: Equatable, Sendable {
    case idle
    case starting
    case running
    /// Routing with a fallback, e.g. one speaker only.
    case degraded(DegradedReason)
    case stopping
    case error(String)

    /// Starting, running, or degraded: the UI shows the engine as on.
    var isActive: Bool {
        switch self {
        case .starting, .running, .degraded: true
        case .idle, .stopping, .error: false
        }
    }

    /// Audio flows through the kernel: running, or degraded.
    var isRouting: Bool {
        switch self {
        case .running, .degraded: true
        case .idle, .starting, .stopping, .error: false
        }
    }

    /// The speaker mono fallback is covering for, if any.
    var missingSpeaker: SpeakerSlot? {
        if case .degraded(.monoFallback(let missing)) = self { return missing }
        return nil
    }
}
