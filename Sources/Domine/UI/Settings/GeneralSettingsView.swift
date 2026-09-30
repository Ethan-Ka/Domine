import SwiftUI

/// Settings > General (docs/mockups/SettingsGeneral.dc.html).
struct GeneralSettingsView: View {
    @Binding var state: GeneralSettingsState
    var actions = GeneralSettingsActions()

    var body: some View {
        Form {
            LabeledContent("Volume keys:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Control Domine with the keyboard volume keys", isOn: $state.volumeKeysEnabled)
                    if !state.accessibilityGranted {
                        Button("Grant access") { actions.grantAccessibility() }
                    }
                }
            }

            Divider()

            LabeledContent("When Domine stops:") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Switch back to the previous output", isOn: $state.restorePreviousOutput)
                    if let name = state.previousOutputName {
                        Text("Also happens on Quit. Previous output: \(name).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                }
            }

            Divider()

            Picker("Closing the window:", selection: $state.closeBehavior) {
                ForEach(GeneralSettingsState.CloseBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            .pickerStyle(.radioGroup)

            LabeledContent {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Start routing when both speakers connect", isOn: $state.startWhenBothConnect)
                    Toggle("Launch at login", isOn: $state.launchAtLogin)
                }
            } label: {
                EmptyView()
            }
        }
        .formStyle(.columns)
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(width: 560, alignment: .top)
    }
}

#if DEBUG
#Preview("General") {
    @Previewable @State var state = GeneralSettingsState.sample
    GeneralSettingsView(state: $state)
}

#Preview("General, access granted") {
    @Previewable @State var state = GeneralSettingsState.sampleGranted
    GeneralSettingsView(state: $state)
}
#endif
