import SwiftUI

/// Settings > General, Setup rows: replay the checklist, and one row per
/// first-run prompt with its status and buttons. Rows go into the parent
/// `Form`, so labels share its right-aligned column.
struct SetupSection: View {
    let state: SetupState
    var actions = SetupActions()
    /// The driver action waiting for the restart warning to be confirmed.
    @State private var confirming: DriverAction?

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

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

            LabeledContent("Accessibility:") {
                row(state.accessibilityText, ok: state.accessibilityGranted, note: state.accessibilityNote) {
                    if !state.accessibilityGranted {
                        Button("Grant Access") { actions.grantAccessibility() }
                        if state.accessibilityLikelyStale {
                            Button("Reveal Domine in Finder") { actions.revealApp() }
                        }
                    }
                }
            }

            LabeledContent("Speakers:") {
                row(state.speakersText, ok: state.connectedGrips >= 2) {
                    if state.connectedGrips < 2 {
                        Button("Open Bluetooth Settings") { actions.openBluetoothSettings() }
                    }
                }
            }

            LabeledContent("Domine output:") {
                row(state.virtualOutputText, ok: state.driverStatus == .installed,
                    note: state.driverFailure, busy: state.driverActivity != nil) {
                    if let action = state.primaryDriverAction {
                        Button(action.buttonTitle) { confirming = action }
                            .disabled(state.driverActivity != nil)
                    } else if state.driverStatus == .notInstalled {
                        Button("Show Install Steps") { actions.showInstallSteps() }
                    }
                    if state.showsRemoveDriver {
                        Button("Remove") { confirming = .remove }
                            .disabled(state.driverActivity != nil)
                    }
                }
            }
            .alert(confirming?.confirmTitle ?? "", isPresented: isConfirming, presenting: confirming) { action in
                Button(action.buttonTitle, role: action == .remove ? .destructive : nil) { actions.driver(action) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(DriverAction.confirmMessage)
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
    private func row(_ status: String, ok: Bool, note: String? = nil, busy: Bool = false,
                     @ViewBuilder buttons: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(status)
            } icon: {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(ok ? Color.green : Color.secondary)
                }
            }
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) { buttons() }
        }
    }
}
