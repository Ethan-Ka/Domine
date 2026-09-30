import SwiftUI

/// Master volume, test tones, and "Sync & Balance…" under the stage.
struct MainBottomBar: View {
    var state: MainWindowState
    var actions: MainWindowActions

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.1")
                    .foregroundStyle(.secondary)
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
                    .accessibilityValue("\(state.masterVolumePercent) percent")
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

    @ViewBuilder
    private func testButton(_ title: String, side: StereoSide) -> some View {
        let button = Button(title) { actions.toggleTestTone(side) }
            .accessibilityValue(state.testToneSide == side ? "Playing" : "")
        if state.testToneSide == side {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }
}

#Preview {
    MainBottomBar(state: SampleStates.playing, actions: .none)
        .frame(width: 640)
}
