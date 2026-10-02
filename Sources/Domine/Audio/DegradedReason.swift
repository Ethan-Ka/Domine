/// Why the engine routes, but not as asked (SPEC section 7).
enum DegradedReason: Equatable, Sendable {
    /// One speaker is gone. The other plays (L + R) / 2 on both of its
    /// channels until the missing one returns.
    case monoFallback(missing: SpeakerSlot)
    /// Quad routing with positions missing (indexes 0 FL, 1 FR, 2 RL, 3 RR).
    /// The kernel folds what is gone into the remaining speakers (SPEC 11.4).
    case quadFallback(missing: [Int])
}
