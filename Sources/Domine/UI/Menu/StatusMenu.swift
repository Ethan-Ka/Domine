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

            VStack(alignment: .leading, spacing: 0) {
                speakerButton(state.left, .frontLeft)
                speakerButton(state.right, .frontRight)
            }
            .font(.callout)

            HStack(spacing: 8) {
                Button { state.isMuted.toggle() } label: {
                    Image(systemName: muteSymbol)
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(state.isMuted ? "Unmute" : "Mute")
                .accessibilityLabel(state.isMuted ? "Unmute" : "Mute")
                Slider(value: $state.masterVolume, in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("Master volume")
                Text("\(Int((state.masterVolume * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            HStack {
                Text("Sound")
                Spacer()
                Picker("Sound", selection: presetBinding) {
                    if state.preset == nil { Text("Custom").tag(PairSettings.Preset?.none) }
                    ForEach(PairSettings.Preset.allCases, id: \.self) { preset in
                        Text(preset.rawValue).tag(PairSettings.Preset?.some(preset))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)

            HStack {
                Text("Room")
                Spacer()
                RoomMenu(
                    rooms: state.rooms, currentRoomID: state.currentRoomID,
                    select: actions.selectRoom, save: actions.saveRoom, manage: actions.manageRooms)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)

            StatusMenuSeparator()

            appsSection

            StatusMenuSeparator()

            Button { actions.swapSides() } label: {
                StatusMenuItemLabel(title: "Swap Left and Right")
            }
            if state.isRouting {
                Button { actions.autoCalibrate() } label: {
                    StatusMenuItemLabel(title: "Auto-calibrate")
                }
            }

            StatusMenuSeparator()

            Button { actions.openMainWindow() } label: {
                StatusMenuItemLabel(title: "Open Domine")
            }
            Button { actions.openSettings() } label: {
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

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Apps")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            if state.apps.isEmpty {
                Text("No apps playing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                ForEach($state.apps) { $app in
                    StatusMenuAppRow(app: $app)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var muteSymbol: String {
        if state.isMuted { return "speaker.slash.fill" }
        return state.masterVolume < 0.34 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    private var presetBinding: Binding<PairSettings.Preset?> {
        Binding(get: { state.preset }, set: { state.preset = $0 })
    }

    private func speakerButton(_ speaker: StatusMenuSpeaker, _ position: SpeakerPosition) -> some View {
        Button { actions.identifySpeaker(position) } label: {
            StatusMenuSpeakerRow(speaker: speaker)
        }
        .disabled(!speaker.isConnected)
        .help("Play identification tone")
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
