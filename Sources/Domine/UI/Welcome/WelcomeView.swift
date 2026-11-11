import SwiftUI

/// First-run checklist (docs/mockups/Welcome.dc.html).
struct WelcomeView: View {
    let state: WelcomeState
    var actions = WelcomeActions()
    /// The restart warning before installing the driver is up.
    @State private var confirmingInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, height: 60)
                    .accessibilityHidden(true)
                Text("Set up Domine")
                    .font(.title.bold())
            }
            .padding(.bottom, 4)

            ForEach(state.steps) { step in
                switch step.kind {
                case .installDriver:
                    WelcomeStepRow(
                        step: step,
                        isBusy: state.isInstallingDriver,
                        note: state.isInstallingDriver ? DriverAction.install.progressText : state.driverFailure,
                        secondaryTitle: step.isDone || state.isInstallingDriver ? nil : "Not Now",
                        secondaryAction: { actions.skipDriver() }
                    ) { confirmingInstall = true }
                default:
                    let isCapture = step.kind == .allowCapture
                    WelcomeStepRow(
                        step: step,
                        isBusy: isCapture && state.isCheckingCapture,
                        secondaryTitle: isCapture && state.showsPrivacySettings && !step.isDone
                            ? "Open Privacy Settings" : nil,
                        secondaryAction: { actions.openPrivacySettings() }
                    ) { actions.perform(step.kind) }
                }
            }

            HStack {
                Spacer()
                Button("Continue") { actions.continueSetup() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .frame(width: 640, alignment: .top)
        .alert(DriverAction.install.confirmTitle, isPresented: $confirmingInstall) {
            Button("Install") { actions.installDriver() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DriverAction.confirmMessage)
        }
    }
}

#if DEBUG
#Preview("Welcome") {
    WelcomeView(state: .sample)
}
#endif
