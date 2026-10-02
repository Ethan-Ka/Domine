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
            demo
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
                Button(state.isClickTestPlaying ? "Stop Click Test" : "Play Click Test",
                       action: actions.playClickTest)
                    .disabled(!state.isClickTestAvailable)
                Button("Auto-calibrate") { actions.autoCalibrate?() }
                    .disabled(actions.autoCalibrate == nil || state.calibrationStatus == .listening)
                    .help(actions.autoCalibrate == nil ? "Needs the Mac's built-in microphone" : "")
            }
            calibrationLine
            if let message = state.clickTestMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            }
            if let latencies = state.reportedLatencies {
                Text(latencies)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var calibrationLine: some View {
        switch state.calibrationStatus {
        case .listening:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Listening…")
                }
                Text("Place the Mac where you sit.")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        case .done(let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .failed(let reason, let offersPrivacySettings):
            HStack(spacing: 8) {
                Text(reason)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                if offersPrivacySettings {
                    Button("Open Privacy Settings", action: actions.openMicrophoneSettings)
                        .controlSize(.small)
                }
            }
            .font(.subheadline)
        case nil:
            EmptyView()
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

    /// Plays the showcase demo so the result can be heard straight away.
    private var demo: some View {
        HStack(spacing: 8) {
            Button(state.demoButtonTitle, action: actions.toggleDemo)
            if let caption = state.demoCaption {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Bass hits and a growl that move around the speakers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
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

#Preview("Demo playing") {
    TuningSheet(state: SampleStates.tuningDemo)
}

#Preview("Extended, left") {
    TuningSheet(state: TuningState(
        delayMs: -120, isExtendedRange: true, balance: -0.2,
        reportedLatencies: SampleStates.tuning.reportedLatencies))
}
