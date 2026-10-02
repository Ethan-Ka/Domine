/// Menu commands. On/off, volume, mute, and sound preset go through the state binding.
struct StatusMenuActions {
    var openMainWindow: @MainActor () -> Void = {}
    /// Opens the Settings window and brings it to the front, since the
    /// app has no Dock icon in background mode.
    var openSettings: @MainActor () -> Void = {}
    /// Plays the identification tone on that speaker.
    var identifySpeaker: @MainActor (SpeakerPosition) -> Void = { _ in }
    var swapSides: @MainActor () -> Void = {}
    var autoCalibrate: @MainActor () -> Void = {}
    var quit: @MainActor () -> Void = {}
}
