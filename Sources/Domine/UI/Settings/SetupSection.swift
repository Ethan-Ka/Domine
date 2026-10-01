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
                    Button("Request Access") { actions.requestCapture() }
                        .disabled(state.isCheckingCapture)
                    if state.captureStatus != .working {
                        Button("Open Privacy Settings") { actions.openPrivacySettings() }
                    }
                }
            }

            LabeledContent("Accessibility:") {
                row(state.accessibilityText, ok: state.accessibilityGranted) {
                    if !state.accessibilityGranted {
                        Button("Grant Access") { actions.grantAccessibility() }
                    }
                }
            }

            LabeledContent("Speakers:") {
                row(state.speakersText, ok: state.connectedGrips >= 2) {
                    Button("Open Bluetooth Settings") { actions.openBluetoothSettings() }
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
    private func row(_ status: String, ok: Bool, @ViewBuilder buttons: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(status)
            } icon: {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(ok ? Color.green : Color.secondary)
            }
            HStack(spacing: 8) { buttons() }
        }
    }
}
