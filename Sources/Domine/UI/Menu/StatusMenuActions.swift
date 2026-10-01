/// Menu commands. On/off and volume go through the state binding.
struct StatusMenuActions {
    var openMainWindow: @MainActor () -> Void = {}
    /// Opens the Settings window and brings it to the front, since the
    /// app has no Dock icon in background mode.
    var openSettings: @MainActor () -> Void = {}
    var quit: @MainActor () -> Void = {}
}
