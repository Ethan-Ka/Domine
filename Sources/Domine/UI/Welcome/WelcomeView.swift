import SwiftUI

/// First-run checklist (docs/mockups/Welcome.dc.html).
struct WelcomeView: View {
    let state: WelcomeState
    var actions = WelcomeActions()

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
                WelcomeStepRow(step: step) { actions.perform(step.kind) }
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
    }
}

#if DEBUG
#Preview("Welcome") {
    WelcomeView(state: .sample)
}
#endif
