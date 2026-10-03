/// Why the engine routes, but not as asked (SPEC section 7).
enum DegradedReason: Equatable, Sendable {
    /// One speaker is gone. The other plays (L + R) / 2 on both of its
    /// channels until the missing one returns.
    case monoFallback(missing: SpeakerSlot)
    /// Surround routing with these speakers (UIDs, list order) missing
    /// (SPEC 13.5 calls it surroundMissing; the name stays from quad mode).
    /// The kernel keeps the full layout and VBAP re-pans their share to the
    /// present neighbours; one left plays the mono sum.
    case quadFallback(missing: [String])
}
