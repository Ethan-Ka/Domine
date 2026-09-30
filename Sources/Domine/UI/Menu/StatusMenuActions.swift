/// Menu commands. On/off and volume go through the state binding;
/// Settings… uses SettingsLink.
struct StatusMenuActions {
    var openMainWindow: @MainActor () -> Void = {}
    var quit: @MainActor () -> Void = {}
}
