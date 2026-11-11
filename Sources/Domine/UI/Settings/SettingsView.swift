import SwiftUI

/// Content for the SwiftUI `Settings` scene: General, Exclusions and Advanced tabs.
struct SettingsView: View {
    @Binding var general: GeneralSettingsState
    @Binding var exclusions: ExclusionsState
    var generalActions = GeneralSettingsActions()
    var setup = SetupState()
    var setupActions = SetupActions()
    /// Nil hides the update checkbox (updates are off for this build).
    var automaticUpdates: Binding<Bool>?
    var exclusionsActions = ExclusionsActions()
    /// Nil hides the Advanced tab (previews and render tests).
    var advanced: Binding<AdvancedSettings>?
    var clockChoices: [AdvancedClockChoice] = []
    var restoreAdvancedDefaults: () -> Void = {}

    var body: some View {
        TabView {
            GeneralSettingsView(state: $general, actions: generalActions, setup: setup, setupActions: setupActions,
                automaticUpdates: automaticUpdates)
                .tabItem { Label("General", systemImage: "gearshape") }
            ExclusionsView(state: $exclusions, actions: exclusionsActions)
                .tabItem { Label("Exclusions", systemImage: "nosign") }
            if let advanced {
                AdvancedSettingsView(settings: advanced, clockChoices: clockChoices,
                                     restoreDefaults: restoreAdvancedDefaults)
                    .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            }
        }
    }
}

#if DEBUG
#Preview("Settings") {
    @Previewable @State var general = GeneralSettingsState.sample
    @Previewable @State var exclusions = ExclusionsState.sample
    SettingsView(general: $general, exclusions: $exclusions)
}
#endif
