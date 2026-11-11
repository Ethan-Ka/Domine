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
                    Toggle("Control Domine with the keyboard volume keys", isOn: $state.volumeKeysEnabled)
                    if state.volumeKeysEnabled {
                        accessibilityStatus
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

            Divider()

            LabeledContent("Startup:") {
                VStack(alignment: .leading, spacing: 8) {
                    option("Launch at login", isOn: $state.launchAtLogin)
                    option("Start routing when speakers connect", isOn: $state.startWhenBothConnect,
                           caption: "Waits for every speaker the current mode uses.")
                    if let automaticUpdates {
                        option("Check for updates automatically", isOn: automaticUpdates, caption: "Once a day.")
                    }
                }
            }

            LabeledContent("Speakers:") {
                VStack(alignment: .leading, spacing: 8) {
                    option("Reconnect speakers that drop", isOn: $state.reconnectDroppedSpeakers)
                    option("Keep speakers from turning off", isOn: $state.keepSpeakersAwake,
                           caption: "Plays a very quiet low tone during silence so the speakers don't power off.")
                }
            }

            LabeledContent("Quitting:") {
                VStack(alignment: .leading, spacing: 8) {
                    option("Pause playback if Domine quits while playing", isOn: $state.pauseOnExit,
                           caption: "So nothing plays from the Mac's own speakers.")
                }
            }

            Divider()

            DisplaySettingsSection(state: $state)

            MenuBarSettingsSection()

            Divider()

            SetupSection(state: setup, actions: setupActions)
        }
        .formStyle(.columns)
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(width: 560, alignment: .top)
    }

    /// Accessibility status for the volume keys, with the grant buttons.
    @ViewBuilder private var accessibilityStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(state.accessibilityGranted ? "Accessibility access granted" : "Accessibility access needed")
            } icon: {
                Image(systemName: state.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(state.accessibilityGranted ? Color.green : Color.secondary)
            }
            if !state.accessibilityGranted {
                if let note = setup.accessibilityNote {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Grant Access") { actions.grantAccessibility() }
                    if setup.accessibilityLikelyStale {
                        Button("Reveal Domine in Finder") { setupActions.revealApp() }
                    }
                }
            }
        }
    }

    private func option(_ title: String, isOn: Binding<Bool>, caption text: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
            if let text { caption(text) }
        }
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
