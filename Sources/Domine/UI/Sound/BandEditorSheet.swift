import SwiftUI

/// Lists the EQ bands with frequency, Q and type. Gain stays on the Sound sheet sliders.
struct BandEditorSheet: View {
    typealias Band = PairSettings.SideEffects.Band
    typealias BandType = PairSettings.SideEffects.BandType

    var bands: [Band]
    var onChange: @MainActor (_ bands: [Band]) -> Void
    var done: @MainActor () -> Void

    private static let freqRange = PairSettings.SideEffects.freqRange
    private static let qRange = PairSettings.SideEffects.qRange
    private static let maxBands = PairSettings.SideEffects.maxBands

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EQ Bands")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Frequency")
                    Text("Q")
                    Text("Type")
                    Color.clear.frame(width: 1, height: 1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(bands.indices, id: \.self) { i in
                    row(i)
                }
            }
            HStack {
                Button("Add Band") { onChange(SoundState.addingBand(to: bands)) }
                    .disabled(bands.count >= Self.maxBands)
                Button("Reset to Default Bands") { onChange(PairSettings.SideEffects.defaultBands) }
                    .disabled(bands == PairSettings.SideEffects.defaultBands)
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(width: 440)
        .onExitCommand(perform: done)
    }

    @ViewBuilder
    private func row(_ i: Int) -> some View {
        let band = bands[i]
        GridRow {
            HStack(spacing: 4) {
                TextField("Frequency", value: binding(i, \.freqHz, Self.freqRange), format: .number.precision(.fractionLength(0)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .accessibilityLabel("Band \(i + 1) frequency")
                Text("Hz").foregroundStyle(.secondary)
                Stepper("Band \(i + 1) frequency", value: Binding(
                    get: { Double(band.freqHz) },
                    set: { v in
                        // Up or down by a twelfth of an octave.
                        let factor = v > Double(band.freqHz) ? 1.0595 : 1 / 1.0595
                        set(i) { $0.freqHz = Self.clamp((band.freqHz * Float(factor)).rounded(), Self.freqRange) }
                    }), in: Double(Self.freqRange.lowerBound)...Double(Self.freqRange.upperBound))
                    .labelsHidden()
            }
            HStack(spacing: 4) {
                TextField("Q", value: binding(i, \.q, Self.qRange), format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                    .accessibilityLabel("Band \(i + 1) Q")
                Stepper("Band \(i + 1) Q", value: Binding(
                    get: { Double(band.q) },
                    set: { v in set(i) { $0.q = Self.clamp((Float(v) * 10).rounded() / 10, Self.qRange) } }),
                    in: Double(Self.qRange.lowerBound)...Double(Self.qRange.upperBound), step: 0.1)
                    .labelsHidden()
            }
            Picker("Band \(i + 1) type", selection: Binding(
                get: { band.type },
                set: { t in set(i) { $0.type = t } })) {
                ForEach(BandType.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                onChange(SoundState.removingBand(at: i, from: bands))
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(bands.count <= 1)
            .help("Remove band")
            .accessibilityLabel("Remove band \(i + 1), \(SoundState.frequencyLabel(band.freqHz))")
        }
    }

    private func binding(_ i: Int, _ key: WritableKeyPath<Band, Float>, _ range: ClosedRange<Float>) -> Binding<Double> {
        Binding(
            get: { bands.indices.contains(i) ? Double(bands[i][keyPath: key]) : 0 },
            set: { v in
                guard v.isFinite else { return }
                set(i) { $0[keyPath: key] = Self.clamp(Float(v), range) }
            })
    }

    private func set(_ i: Int, _ change: (inout Band) -> Void) {
        guard bands.indices.contains(i) else { return }
        var copy = bands
        change(&copy[i])
        onChange(copy)
    }

    private static func clamp(_ v: Float, _ r: ClosedRange<Float>) -> Float {
        min(max(v, r.lowerBound), r.upperBound)
    }
}

#Preview {
    BandEditorSheet(bands: PairSettings.SideEffects.defaultBands, onChange: { _ in }, done: {})
}
