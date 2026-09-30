/// Side effects Settings > General cannot express as a state change.
struct GeneralSettingsActions {
    /// Ask for Accessibility permission for the volume key tap (SPEC 4b).
    var grantAccessibility: @MainActor () -> Void = {}
}
