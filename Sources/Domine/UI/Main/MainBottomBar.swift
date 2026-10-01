import SwiftUI

/// Master volume, test tones, and "Sync & Balance…" under the stage.
struct MainBottomBar: View {
    var state: MainWindowState
    var actions: MainWindowActions

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: state.isMuted ? "speaker.slash" : "speaker.wave.1")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text("Master")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { state.masterVolume },
                    set: { actions.setMasterVolume($0) }), in: 0...1)
                    .labelsHidden()
                    .accessibilityLabel("Master volume")
                    .accessibilityValue(state.isMuted ? "Muted, \(state.masterVolumePercent) percent" : "\(state.masterVolumePercent) percent")
                Text("\(state.masterVolumePercent)%")
                    .font(.callout)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 6) {
                testButton("Test L", side: .left)
                testButton("Test R", side: .right)
            }

            Button("Sync & Balance…", action: actions.openTuning)
        }
        .padding(.horizontal, 20)
        .frame(height: 84)
    }

    /// One stable toggle per side. A button that swapped styles was rebuilt on
    /// every change and could miss the click that turns the tone off.
    private func testButton(_ title: String, side: StereoSide) -> some View {
        Toggle(title, isOn: Binding(
            get: { state.testToneSide == side },
            set: { _ in actions.toggleTestTone(side) }))
            .toggleStyle(.button)
            .disabled(!state.canPlayTestTones)
    }
}

#Preview {
    MainBottomBar(state: SampleStates.playing, actions: .none)
        .frame(width: 640)
}
