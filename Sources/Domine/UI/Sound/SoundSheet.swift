import SwiftUI

/// EQ, bass, and compressor for the pair.
struct SoundSheet: View {
    var state: SoundState
    var actions: SoundActions = .none
    @State private var side: StereoSide = .left

    static let width: CGFloat = 420
    private static let customTag = "Custom"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sound")
                .font(.headline)
            HStack {
                Picker("Preset", selection: presetBinding) {
                    if state.preset == nil { Text(Self.customTag).tag(Self.customTag) }
                    ForEach(PairSettings.Preset.allCases, id: \.self) {
                        Text($0.rawValue).tag($0.rawValue)
                    }
                }
                .fixedSize()
                Spacer()
            }
            linkRow
            GroupBox { eq.padding(2) }
            GroupBox { bass.padding(2) }
            GroupBox { compressor.padding(2) }
            HStack {
                Button("Reset", action: actions.reset)
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
    private var current: PairSettings.SideEffects { state.side(editedSide) }

    private var presetBinding: Binding<String> {
        Binding(
            get: { state.preset?.rawValue ?? Self.customTag },
            set: { name in
                if let p = PairSettings.Preset(rawValue: name) {
                    actions.setEffects(state.applying(preset: p))
                }
            })
    }

    private func edit(_ change: (inout PairSettings.SideEffects) -> Void) {
        actions.setEffects(state.applying(to: editedSide, change))
    }

    private var linkRow: some View {
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
                        Slider(
                            value: Binding(
                                get: { Double(current.eqBands[i].gainDb) },
                                set: { v in edit { $0.eqBands[i].gainDb = Float(v.rounded()) } }),
                            in: Double(SoundState.gainRange.lowerBound)...Double(SoundState.gainRange.upperBound))
                            .labelsHidden()
                            .frame(width: 110)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 24, height: 110)
                            .accessibilityLabel("\(SoundState.bandLabels[i]) hertz")
                            .accessibilityValue("\(Int(current.eqBands[i].gainDb)) decibels")
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
