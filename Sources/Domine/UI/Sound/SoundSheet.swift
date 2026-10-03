import SwiftUI

/// EQ, bass, and compressor for the pair, or in Surround for the speakers.
struct SoundSheet: View {
    var state: SoundState
    var actions: SoundActions = .none
    @State private var side: StereoSide = .left
    /// Surround: the speaker picked while effects are unlinked.
    @State private var surroundSelection: String?

    static let width: CGFloat = 420
    private static let customTag = "Custom"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sound")
                .font(.headline)
            HStack {
                Picker("Preset", selection: presetBinding) {
                    if preset == nil { Text(Self.customTag).tag(Self.customTag) }
                    ForEach(PairSettings.Preset.allCases, id: \.self) {
                        Text($0.rawValue).tag($0.rawValue)
                    }
                }
                .fixedSize()
                Spacer()
            }
            if let surround = state.surround {
                surroundLinkRow(surround)
            } else {
                speakerLinkRow
            }
            GroupBox { eq.padding(2) }
            GroupBox { bass.padding(2) }
            GroupBox { compressor.padding(2) }
            HStack {
                Button("Reset", action: reset)
                Spacer()
                Button("Done", action: actions.done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(width: Self.width)
        .onExitCommand(perform: actions.done)
    }

    private var editedSide: StereoSide { state.effects.linkSpeakers ? .left : side }

    /// The Surround speaker being edited; nil in Stereo.
    private var surroundUID: String? {
        state.surround?.editedUID(selection: surroundSelection)
    }

    private var current: PairSettings.SideEffects {
        if let surround = state.surround, let uid = surroundUID { return surround.effects(for: uid) }
        return state.side(editedSide)
    }

    /// The preset the edited settings match, or nil when edited.
    private var preset: PairSettings.Preset? {
        guard state.surround != nil else { return state.preset }
        let shown = current
        return PairSettings.Preset.allCases.first { $0.settings.left == shown }
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { preset?.rawValue ?? Self.customTag },
            set: { name in
                guard let p = PairSettings.Preset(rawValue: name) else { return }
                if state.surround != nil {
                    if let uid = surroundUID { actions.setSurroundEffects(uid, p.settings.left) }
                } else {
                    actions.setEffects(state.applying(preset: p))
                }
            })
    }

    private func edit(_ change: (inout PairSettings.SideEffects) -> Void) {
        if state.surround != nil {
            guard let uid = surroundUID else { return }
            var effects = current
            change(&effects)
            actions.setSurroundEffects(uid, effects)
        } else {
            actions.setEffects(state.applying(to: editedSide, change))
        }
    }

    /// Surround with unlinked effects resets only the picked speaker.
    private func reset() {
        if let surround = state.surround, !surround.isLinked, let uid = surroundUID {
            actions.setSurroundEffects(uid, PairSettings.SideEffects())
        } else {
            actions.reset()
        }
    }

    private func surroundLinkRow(_ surround: SurroundSound) -> some View {
        HStack(spacing: 12) {
            Toggle("Link speakers", isOn: Binding(
                get: { surround.isLinked },
                set: { actions.setSurroundLinked($0) }))
                .toggleStyle(.checkbox)
                .fixedSize()
            if !surround.isLinked {
                Picker("Speaker", selection: Binding(
                    get: { surroundUID ?? "" },
                    set: { surroundSelection = $0 })) {
                    ForEach(surround.speakers) { speaker in
                        Text(speaker.label).tag(speaker.uid)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Speaker")
            }
            Spacer()
        }
    }

    private var speakerLinkRow: some View {
        HStack(spacing: 12) {
            Toggle("Link speakers", isOn: Binding(
                get: { state.effects.linkSpeakers },
                set: { actions.setEffects(state.setting(link: $0)) }))
                .toggleStyle(.checkbox)
                .fixedSize()
            if !state.effects.linkSpeakers {
                Picker("Side", selection: $side) {
                    Text("Left").tag(StereoSide.left)
                    Text("Right").tag(StereoSide.right)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
            Spacer()
        }
    }

    private var eq: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("EQ", isOn: Binding(
                get: { current.eqEnabled }, set: { v in edit { $0.eqEnabled = v } }))
                .toggleStyle(.checkbox)
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { i in
                    VStack(spacing: 6) {
                        VerticalGainSlider(
                            value: Double(current.eqBands[i].gainDb),
                            range: Double(SoundState.gainRange.lowerBound)...Double(SoundState.gainRange.upperBound),
                            axLabel: "\(SoundState.bandLabels[i]) gain",
                            axValue: "\(Int(current.eqBands[i].gainDb)) dB",
                            onChange: { v in edit { $0.eqBands[i].gainDb = Float(v.rounded()) } })
                            .frame(width: 24, height: 110)
                        Text(SoundState.bandLabels[i])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .disabled(!current.eqEnabled)
        }
    }

    private var bass: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Bass", isOn: Binding(
                get: { current.bassEnabled }, set: { v in edit { $0.bassEnabled = v } }))
                .toggleStyle(.checkbox)
            Slider(value: Binding(
                get: { Double(current.bassAmount) },
                set: { v in edit { $0.bassAmount = Float(v) } }), in: 0...1)
                .labelsHidden()
                .accessibilityLabel("Bass amount")
                .disabled(!current.bassEnabled)
        }
    }

    private var compressor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Compressor", isOn: Binding(
                get: { current.compressorEnabled }, set: { v in edit { $0.compressorEnabled = v } }))
                .toggleStyle(.checkbox)
            HStack {
                Text("Amount").font(.callout)
                Slider(value: Binding(
                    get: { Double(current.compressorAmount) },
                    set: { v in edit { $0.compressorAmount = Float(v) } }), in: 0...1)
                    .labelsHidden()
                    .accessibilityLabel("Compressor amount")
            }
            .disabled(!current.compressorEnabled)
        }
    }
}

#Preview("Night") {
    SoundSheet(state: SoundState(effects: PairSettings.Preset.night.settings))
}

#Preview("Surround, unlinked") {
    SoundSheet(state: SampleStates.soundSurround)
}
