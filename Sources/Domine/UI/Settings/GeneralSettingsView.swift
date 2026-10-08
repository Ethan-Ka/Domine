import SwiftUI

/// Settings > General (docs/mockups/SettingsGeneral.dc.html).
struct GeneralSettingsView: View {
    @Binding var state: GeneralSettingsState
    var actions = GeneralSettingsActions()
    var setup = SetupState()
    var setupActions = SetupActions()
    /// Automatic update check setting. Nil hides the checkbox.
    var automaticUpdates: Binding<Bool>?

    var body: some View {
        Form {
            LabeledContent("Volume keys:") {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Control Domine with the keyboard volume keys", isOn: $state.volumeKeysEnabled)
                        if state.showsAccessibilityPrompt {
                            caption(GeneralSettingsState.accessibilityMissingCaption)
                        }
                    }
                    if state.showsAccessibilityPrompt {
                        Button("Grant Access") { actions.grantAccessibility() }
                    }
                }
            }

            Divider()

            LabeledContent("When Domine stops:") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Switch back to the previous output", isOn: $state.restorePreviousOutput)
                    if let restoreCaption = state.restoreCaption {
                        caption(restoreCaption)
                    }
                }
            }

            Divider()

            LabeledContent("Closing the window:") {
                VStack(alignment: .leading, spacing: 2) {
                    Picker("Closing the window:", selection: $state.closeBehavior) {
                        ForEach(GeneralSettingsState.CloseBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }

            LabeledContent {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Start routing when both speakers connect", isOn: $state.startWhenBothConnect)
                    Toggle("Reconnect speakers that drop", isOn: $state.reconnectDroppedSpeakers)
                    Toggle("Launch at login", isOn: $state.launchAtLogin)
                    if let automaticUpdates {
                        Toggle("Check for updates automatically", isOn: automaticUpdates)
                    }
                }
            } label: {
                EmptyView()
            }

            Divider()

            SetupSection(state: setup, actions: setupActions)
        }
        .formStyle(.columns)
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(width: 560, alignment: .top)
    }

    /// Secondary text under a checkbox, aligned with its title.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 20)
    }
}

#if DEBUG
#Preview("General") {
    @Previewable @State var state = GeneralSettingsState.sample
    GeneralSettingsView(state: $state)
}

#Preview("General, setup done") {
    @Previewable @State var state = GeneralSettingsState.sampleGranted
    GeneralSettingsView(state: $state, setup: .sampleDone)
}

#Preview("General, access granted") {
    @Previewable @State var state = GeneralSettingsState.sampleGranted
    GeneralSettingsView(state: $state)
}
#endif
