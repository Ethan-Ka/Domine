import SwiftUI

/// Master volume, test tones, and "Sync & Balance…" under the
/// stage. Surround adds its sliders, "Add Speaker…" and Presets above.
struct MainBottomBar: View {
    var state: MainWindowState
    var actions: MainWindowActions

    var body: some View {
        VStack(spacing: 10) {
            if state.mode == .surround { surroundControls }
            mainRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, state.mode == .surround ? 12 : 0)
        .frame(height: state.mode == .surround ? nil : 84)
    }

    private var surroundControls: some View {
        let controls = state.surround
        return VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    compactSlider("Width", value: controls.width, range: SurroundControls.widthRange,
                                  text: controls.widthText, set: actions.setSurroundWidth)
                    compactSlider("Surround", value: controls.level, range: 0...1,
                                  text: controls.levelText, set: actions.setSurroundLevel)
                    Button("Add Speaker…", action: actions.addSurroundSpeaker)
                        .disabled(!state.canAddSurroundSpeaker)
                }
                GridRow {
                    HStack(spacing: 4) {
                        compactSlider("Orbit", value: controls.orbitRate, range: SurroundControls.orbitRange,
                                      text: controls.orbitText, set: actions.setOrbitRate)
                        Button(action: actions.resetSurroundOrbit) {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Turn the orbit back to the front")
                        .accessibilityLabel("Reset orbit")
                    }
                    compactSlider("Rotation", value: controls.rotation, range: SurroundControls.rotationRange,
                                  text: controls.rotationText, set: actions.setSurroundRotation)
                    Menu("Presets") {
                        ForEach(SurroundPreset.allCases, id: \.self) { preset in
                            Button(preset.title) { actions.applySurroundPreset(preset) }
                                .disabled(!preset.isEnabled(speakerCount: state.surroundCards.count))
                        }
                    }
                    .fixedSize()
                }
            }
            if controls.showsBluetoothWarning {
                Label(SurroundControls.bluetoothWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactSlider(_ title: String, value: Double, range: ClosedRange<Double>,
                               text: String, set: @escaping @MainActor @Sendable (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { value }, set: { set($0) }), in: range)
                .labelsHidden()
                .frame(minWidth: 60, maxWidth: 160)
                .accessibilityLabel(title)
                .accessibilityValue(text)
            Text(text)
                .font(.callout)
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
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

#Preview("Stereo") {
    MainBottomBar(state: SampleStates.playing, actions: .none)
        .frame(width: 640)
}

#Preview("Surround") {
    MainBottomBar(state: SampleStates.surround, actions: .none)
        .frame(width: 640)
}
