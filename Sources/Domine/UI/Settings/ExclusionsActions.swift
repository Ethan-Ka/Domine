/// Side effects Settings > Exclusions cannot express as a state change.
struct ExclusionsActions {
    /// Let the user pick any app (for example with an NSOpenPanel) and add it.
    var chooseApp: @MainActor () -> Void = {}
}
