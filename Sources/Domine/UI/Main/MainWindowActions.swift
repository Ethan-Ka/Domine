/// What the main window can ask the model to do.
struct MainWindowActions: Sendable {
    var setOn: @MainActor @Sendable (Bool) -> Void = { _ in }
    var setMode: @MainActor @Sendable (RoutingMode) -> Void = { _ in }
    var swap: @MainActor @Sendable () -> Void = {}
    var setMasterVolume: @MainActor @Sendable (Double) -> Void = { _ in }
    /// Plays one short tone on that side.
    var playTestTone: @MainActor @Sendable (StereoSide) -> Void = { _ in }
    /// "Test Speakers" in Surround: one chime per speaker, in turn.
    var testSurroundSpeakers: @MainActor @Sendable () -> Void = {}
    /// A card was clicked; the owner presents `AssignSheet`.
    var selectSpeaker: @MainActor @Sendable (SpeakerPosition) -> Void = { _ in }
    /// "Reconnect" on a disconnected speaker card.
    var reconnectSpeaker: @MainActor @Sendable (_ uid: String) -> Void = { _ in }
    /// "Sync & Balance…" was clicked; the owner presents `TuningSheet`.
    var openTuning: @MainActor @Sendable () -> Void = {}

    /// "Sound…" was clicked; the owner presents `SoundSheet`.
    var openSound: @MainActor @Sendable () -> Void = {}

    // Surround (SPEC section 13). Speakers are keyed by device UID.
    /// "Add Speaker…": the owner presents `AssignSheet` in add mode.
    var addSurroundSpeaker: @MainActor @Sendable () -> Void = {}
    /// A Surround card was clicked or "Choose Speaker…" picked: the owner
    /// presents `AssignSheet` to replace that speaker.
    var chooseSurroundSpeaker: @MainActor @Sendable (_ uid: String) -> Void = { _ in }
    var removeSurroundSpeaker: @MainActor @Sendable (_ uid: String) -> Void = { _ in }
    /// Live while a card is dragged: degrees and metres.
    var moveSurroundSpeaker: @MainActor @Sendable (_ uid: String, _ azimuth: Double, _ distance: Double) -> Void = { _, _, _ in }
    /// The orbit phase in degrees as the speakers play it; nil when no
    /// surround routing runs (the stage then keeps its own clock).
    var heardOrbitPhase: @MainActor @Sendable () -> Double? = { nil }
    /// Returns the orbit to its starting angle.
    var resetSurroundOrbit: @MainActor @Sendable () -> Void = {}
    /// The card's "Play Test Tone".
    var playSurroundTestTone: @MainActor @Sendable (_ uid: String) -> Void = { _ in }
    var applySurroundPreset: @MainActor @Sendable (SurroundPreset) -> Void = { _ in }
    var setSurroundWidth: @MainActor @Sendable (Double) -> Void = { _ in }
    var setSurroundLevel: @MainActor @Sendable (Double) -> Void = { _ in }
    var setOrbitRate: @MainActor @Sendable (Double) -> Void = { _ in }
    var setSurroundRotation: @MainActor @Sendable (Double) -> Void = { _ in }

    /// "Play Demo" / "Stop Demo".
    var toggleDemo: @MainActor @Sendable () -> Void = {}

    var selectRoom: @MainActor @Sendable (Room.ID) -> Void = { _ in }
    /// "Save Current Setup…": the owner presents `SaveRoomSheet`.
    var saveRoom: @MainActor @Sendable () -> Void = {}
    /// "Manage Rooms…": the owner presents `ManageRoomsSheet`.
    var manageRooms: @MainActor @Sendable () -> Void = {}

    static let none = MainWindowActions()
}
