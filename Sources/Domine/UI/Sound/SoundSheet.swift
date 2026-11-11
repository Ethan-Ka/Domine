import SwiftUI

/// EQ, bass, and compressor for the pair, or in Surround for the speakers.
struct SoundSheet: View {
    var state: SoundState
    var actions: SoundActions = .none
    @State private var side: StereoSide = .left
    /// Surround: the speaker picked while effects are unlinked.
    @State private var surroundSelection: String?
    /// The EQ band being dragged, for the live readout.
    @State private var draggingBand: Int?
    @State private var showingBands = false

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
            if state.surround == nil { GroupBox { crossfeedControls.padding(2) } }
            GroupBox { eq.padding(2) }
            GroupBox { bass.padding(2) }
            GroupBox { compressor.padding(2) }
            GroupBox { nightMode.padding(2) }
            HStack {
                Button(resetTitle, action: reset)
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

    private var resetTitle: String {
        if let surround = state.surround { return surround.isLinked ? "Reset All" : "Reset This Speaker" }
        return state.effects.linkSpeakers ? "Reset All" : "Reset This Speaker"
    }

    private func surroundLinkRow(_ surround: SurroundSound) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("Same effects on all speakers", isOn: Binding(
                    get: { surround.isLinked },
                    set: { actions.setSurroundLinked($0) }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Spacer()
            }
            if !surround.isLinked {
                HStack(spacing: 8) {
                    Text("Editing: \(surround.speakers.first { $0.uid == surroundUID }?.label ?? "")")
                        .font(.callout)
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
                    Spacer()
                }
            }
            Toggle("Mix left and right together", isOn: Binding(
                get: { surround.isMono },
                set: { actions.setSurroundMono($0) }))
                .toggleStyle(.checkbox)
                .fixedSize()
            Text("Every speaker plays the full mix, not just its own side.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
    }

    private var speakerLinkRow: some View {
        HStack(spacing: 12) {
            Toggle("Same effects on all speakers", isOn: Binding(
                get: { state.effects.linkSpeakers },
                set: { actions.setEffects(state.setting(link: $0)) }))
                .toggleStyle(.checkbox)
                .fixedSize()
            if !state.effects.linkSpeakers {
                Text("Editing: \(side == .left ? "Left" : "Right")")
                    .font(.callout)
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

    private var crossfeedControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Crossfeed").font(.callout)
                Slider(value: Binding(
                    get: { state.sameOnBoth ? 1 : state.crossfeed },
                    set: { actions.setCrossfeed($0) }), in: 0...1)
                    .labelsHidden()
                    .accessibilityLabel("Crossfeed")
                    .disabled(state.sameOnBoth)
                Text("\(Int(((state.sameOnBoth ? 1 : state.crossfeed) * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Toggle("Same sound on both speakers", isOn: Binding(
                get: { state.sameOnBoth },
                set: { actions.setSameOnBoth($0) }))
                .toggleStyle(.checkbox)
        }
    }

    private var eq: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("EQ", isOn: Binding(
                    get: { current.eqEnabled }, set: { v in edit { $0.eqEnabled = v } }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Edit Bands\u{2026}") { showingBands = true }
            }
            HStack(spacing: 0) {
                ForEach(current.eqBands.indices, id: \.self) { i in
                    let band = current.eqBands[i]
                    let label = SoundState.frequencyLabel(band.freqHz)
                    VStack(spacing: 6) {
                        Text(draggingBand == i ? SoundState.gainText(band.gainDb) : " ")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.primary)
                            .frame(height: 14)
                            .accessibilityHidden(true)
                        VerticalGainSlider(
                            value: Double(band.type.usesGain ? band.gainDb : 0),
                            range: Double(SoundState.gainRange.lowerBound)...Double(SoundState.gainRange.upperBound),
                            axLabel: "\(label) gain",
                            axValue: band.type.usesGain ? SoundState.gainLabel(band.gainDb) : "Notch",
                            onChange: { v in
                                edit { fx in
                                    guard fx.eqBands.indices.contains(i) else { return }
                                    fx.eqBands[i].gainDb = Float(v.rounded())
                                }
                            },
                            onDragging: { draggingBand = $0 ? i : (draggingBand == i ? nil : draggingBand) })
                            .frame(width: 24, height: 110)
                            .disabled(!band.type.usesGain)
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(band.type.label), \(label), \(SoundState.qLabel(band.q))")
                }
            }
            .disabled(!current.eqEnabled)
        }
        .sheet(isPresented: $showingBands) {
            BandEditorSheet(
                bands: current.eqBands,
                onChange: { bands in edit { $0.eqBands = bands } },
                done: { showingBands = false })
        }
    }

    private var nightMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Night mode", isOn: Binding(
                get: { current.nightMode },
                set: { on in
                    if state.surround != nil {
                        edit { $0.nightMode = on }
                    } else {
                        actions.setEffects(state.effects.settingNightMode(on))
                    }
                }))
                .toggleStyle(.checkbox)
                .help("Quieter peaks and fuller sound at low volume")
            Picker("Night mode strength", selection: Binding(
                get: { current.nightStrength },
                set: { strength in
                    if state.surround != nil {
                        edit { $0.nightStrength = strength }
                    } else {
                        actions.setEffects(state.effects.settingNightStrength(strength))
                    }
                })) {
                ForEach(PairSettings.NightStrength.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .font(.callout)
            .disabled(!current.nightMode)
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
