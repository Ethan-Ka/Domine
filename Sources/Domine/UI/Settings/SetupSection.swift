import SwiftUI

/// Settings > General, Setup rows: replay the checklist, and one row per
/// first-run prompt with its status and buttons. Rows go into the parent
/// `Form`, so labels share its right-aligned column.
struct SetupSection: View {
    let state: SetupState
    var actions = SetupActions()

    var body: some View {
        Group {
            LabeledContent("Setup:") {
                Button("Show Setup Again…") { actions.showSetupAgain() }
            }

            LabeledContent("Audio capture:") {
                row(state.captureText, ok: state.captureStatus == .working) {
                    if state.captureStatus != .working {
                        Button("Request Access") { actions.requestCapture() }
                            .disabled(state.isCheckingCapture)
                        Button("Open Privacy Settings") { actions.openPrivacySettings() }
                    }
                }
            }

            LabeledContent("Speakers:") {
                row(state.speakersText, ok: state.hasEnoughSpeakers) {
                    if !state.hasEnoughSpeakers {
                        Button("Bluetooth Speakers\u{2026}") { actions.openBluetoothSpeakers() }
                    }
                }
            }

            LabeledContent("Domine output:") {
                row(state.virtualOutputText, ok: state.virtualOutputInstalled) {
                    if !state.virtualOutputInstalled {
                        Button("Show Install Steps") { actions.showInstallSteps() }
                    }
                }
            }

            if state.loginItemNeedsApproval {
                LabeledContent("Login item:") {
                    row("Needs approval", ok: false) {
                        Button("Open Login Items") { actions.openLoginItems() }
                    }
                }
            }
        }
    }

    /// Status text on the first line, buttons under it.
    private func row(_ status: String, ok: Bool, note: String? = nil, @ViewBuilder buttons: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(status)
            } icon: {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(ok ? Color.green : Color.secondary)
            }
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) { buttons() }
        }
    }
}
