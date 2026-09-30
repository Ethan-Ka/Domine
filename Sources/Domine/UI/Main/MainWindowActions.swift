/// What the main window can ask the model to do.
struct MainWindowActions: Sendable {
    var setOn: @MainActor @Sendable (Bool) -> Void = { _ in }
    var setMode: @MainActor @Sendable (RoutingMode) -> Void = { _ in }
    var swap: @MainActor @Sendable () -> Void = {}
    var setMasterVolume: @MainActor @Sendable (Double) -> Void = { _ in }
    /// Starts the tone on that side, or stops it if it is already playing.
    var toggleTestTone: @MainActor @Sendable (StereoSide) -> Void = { _ in }
    /// A card was clicked; the owner presents `AssignSheet`.
    var selectSpeaker: @MainActor @Sendable (SpeakerPosition) -> Void = { _ in }
    /// "Sync & Balance…" was clicked; the owner presents `TuningSheet`.
    var openTuning: @MainActor @Sendable () -> Void = {}

    static let none = MainWindowActions()
}
