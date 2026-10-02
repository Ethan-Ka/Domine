import SwiftUI

/// Master volume, test tones, and "Sync & Balance…" under the stage.
struct MainBottomBar: View {
    var state: MainWindowState
    var actions: MainWindowActions

    var body: some View {
        VStack(spacing: 10) {
            if state.mode == .quad { rearRow }
            mainRow
        }
        .padding(.horizontal, 20)
        .frame(height: state.mode == .quad ? 120 : 84)
    }

    private var rearRow: some View {
        HStack(spacing: 16) {
            Picker("Rear", selection: Binding(
                get: { state.rearMode },
                set: { actions.setRearMode($0) })) {
                ForEach(RearMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .accessibilityLabel("Rear")

            HStack(spacing: 8) {
                Text("Rear level")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { state.rearLevel },
                    set: { actions.setRearLevel($0) }), in: 0...1)
                    .labelsHidden()
                    .accessibilityLabel("Rear level")
                    .accessibilityValue("\(Int((state.rearLevel * 100).rounded())) percent")
                Text("\(Int((state.rearLevel * 100).rounded()))%")
                    .font(.callout)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
                    .accessibilityHidden(true)
            }

            if state.rearMode == .spatial {
                compactSlider("Spatial", value: state.spatialAmount, range: 0...1,
                              text: "\(Int((state.spatialAmount * 100).rounded()))%",
                              set: actions.setSpatialAmount)
                compactSlider("Room", value: state.spatialRoomMs, range: 5...30,
                              text: "\(Int(state.spatialRoomMs.rounded())) ms",
                              set: actions.setSpatialRoom)
            }
        }
    }

    private func compactSlider(_ title: String, value: Double, range: ClosedRange<Double>,
                               text: String, set: @escaping @MainActor @Sendable (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { value }, set: { set($0) }), in: range)
                .labelsHidden()
                .frame(minWidth: 60, maxWidth: 90)
                .accessibilityLabel(title)
                .accessibilityValue(text)
            Text(text)
                .font(.callout)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private var mainRow: some View {
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

            Button("Sound…", action: actions.openSound)
            Button("Sync & Balance…", action: actions.openTuning)
        }
    }

    /// A plain button: each press plays one short tone. The side that is
    /// playing is shown by the accessibility value only, so the button keeps
    /// a single stable identity.
    private func testButton(_ title: String, side: StereoSide) -> some View {
        Button(title) { actions.playTestTone(side) }
            .accessibilityValue(state.testToneSide == side ? "Playing" : "")
            .disabled(!state.canPlayTestTones)
    }
}

#Preview {
    MainBottomBar(state: SampleStates.playing, actions: .none)
        .frame(width: 640)
}
