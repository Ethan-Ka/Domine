/// What the Sound sheet can ask the model to do.
struct SoundActions: Sendable {
    var setEffects: @MainActor @Sendable (PairSettings.EffectsSettings) -> Void = { _ in }
    var setQuad: @MainActor @Sendable (QuadSettings) -> Void = { _ in }
    var reset: @MainActor @Sendable () -> Void = {}
    var done: @MainActor @Sendable () -> Void = {}

    static let none = SoundActions()
}
