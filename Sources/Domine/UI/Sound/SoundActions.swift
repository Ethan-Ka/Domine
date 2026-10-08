/// What the Sound sheet can ask the model to do.
struct SoundActions: Sendable {
    var setEffects: @MainActor @Sendable (PairSettings.EffectsSettings) -> Void = { _ in }
    var setCrossfeed: @MainActor @Sendable (Double) -> Void = { _ in }
    var setSameOnBoth: @MainActor @Sendable (Bool) -> Void = { _ in }
    var reset: @MainActor @Sendable () -> Void = {}
    var done: @MainActor @Sendable () -> Void = {}
    /// Surround: one speaker's effects (the shared ones while linked).
    var setSurroundEffects: @MainActor @Sendable (_ uid: String, _ effects: PairSettings.SideEffects) -> Void = { _, _ in }
    var setSurroundLinked: @MainActor @Sendable (Bool) -> Void = { _ in }
    var setSurroundMono: @MainActor @Sendable (Bool) -> Void = { _ in }

    static let none = SoundActions()
}
