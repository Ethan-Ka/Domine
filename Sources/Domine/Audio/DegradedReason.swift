/// Why the engine routes, but not as asked (SPEC section 7).
enum DegradedReason: Equatable, Sendable {
    /// One speaker is gone. The other plays (L + R) / 2 on both of its
    /// channels until the missing one returns.
    case monoFallback(missing: SpeakerSlot)
}
