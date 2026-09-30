import SwiftUI

/// Delay offset and balance (docs/mockups/Tuning.dc.html).
struct TuningSheet: View {
    var state: TuningState
    var actions: TuningActions = .none

    /// Wider than the mockup's 440 pt so the added Auto-calibrate button fits
    /// on the Extended range row.
    static let width: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync & Balance")
                .font(.headline)
            GroupBox { timing.padding(2) }
            GroupBox { level.padding(2) }
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

    private var timing: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("TIMING")
            VStack(spacing: 4) {
                readoutRow("Delay offset", value: state.delayReadout)
                Slider(
                    value: Binding(
                        get: { Double(state.delayMs) },
                        set: { actions.setDelayMs(Int($0.rounded())) }),
                    // Rounded in the setter rather than `step:`, which draws
                    // a tick for every millisecond.
                    in: Double(state.delayRange.lowerBound)...Double(state.delayRange.upperBound))
                    .labelsHidden()
                    .accessibilityLabel("Delay offset")
                    .accessibilityValue(state.delayReadout)
                endLabels("Delay left", "Delay right")
            }
            HStack(spacing: 8) {
                Toggle("Extended range (±300 ms)", isOn: Binding(
                    get: { state.isExtendedRange },
                    set: { actions.setExtendedRange($0) }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Spacer(minLength: 8)
                Button("Play Click Test", action: actions.playClickTest)
                Button("Auto-calibrate") { actions.autoCalibrate?() }
                    .disabled(actions.autoCalibrate == nil)
                    .help(actions.autoCalibrate == nil ? "Coming in a later version" : "")
            }
            if let latencies = state.reportedLatencies {
                Text(latencies)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var level: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("LEVEL")
            VStack(spacing: 4) {
                readoutRow("Balance", value: state.balanceReadout)
                Slider(
                    value: Binding(
                        get: { state.balance },
                        set: { actions.setBalance($0) }),
                    in: -1...1)
                    .labelsHidden()
                    .accessibilityLabel("Balance")
                    .accessibilityValue(state.balanceReadout)
                endLabels("Left", "Right")
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func readoutRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityHidden(true)
    }

    private func endLabels(_ leading: String, _ trailing: String) -> some View {
        HStack {
            Text(leading)
            Spacer()
            Text(trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

#Preview("Right +4 ms") {
    TuningSheet(state: SampleStates.tuning)
}

#Preview("Extended, left") {
    TuningSheet(state: TuningState(
        delayMs: -120, isExtendedRange: true, balance: -0.2,
        reportedLatencies: SampleStates.tuning.reportedLatencies))
}
