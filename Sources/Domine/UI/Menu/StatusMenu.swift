import SwiftUI

/// MenuBarExtra content for background mode (docs/mockups/MenuBar.dc.html).
/// Use with `.menuBarExtraStyle(.window)`; the slider and switch need a window.
struct StatusMenu: View {
    @Binding var state: StatusMenuState
    var actions = StatusMenuActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Domine").fontWeight(.semibold)
                    Text(state.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Domine output", isOn: $state.isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            StatusMenuSeparator()

            VStack(alignment: .leading, spacing: 6) {
                StatusMenuSpeakerRow(speaker: state.left)
                StatusMenuSpeakerRow(speaker: state.right)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.1.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: $state.masterVolume, in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("Master volume")
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 8)

            StatusMenuSeparator()

            Button { actions.openMainWindow() } label: {
                StatusMenuItemLabel(title: "Open Domine")
            }
            SettingsLink {
                StatusMenuItemLabel(title: "Settings…", shortcut: "⌘,")
            }
            .keyboardShortcut(",", modifiers: .command)

            StatusMenuSeparator()

            Button { actions.quit() } label: {
                StatusMenuItemLabel(title: "Quit Domine", shortcut: "⌘Q")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(StatusMenuItemStyle())
        .padding(6)
        .frame(width: 300)
    }
}

#if DEBUG
#Preview("Status menu") {
    @Previewable @State var state = StatusMenuState.sample
    StatusMenu(state: $state)
}

#Preview("Status menu, left off") {
    @Previewable @State var state = StatusMenuState.sampleLeftOff
    StatusMenu(state: $state)
}
#endif
