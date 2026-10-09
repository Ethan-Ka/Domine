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
            if let rows = state.surroundRows {
                GroupBox { surroundTiming(rows).padding(2) }
                GroupBox { surroundLevel(rows).padding(2) }
            } else {
                GroupBox { timing.padding(2) }
                GroupBox { level.padding(2) }
            }
            demo
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
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            guard state.surroundRows == nil,
                  press.key == .leftArrow || press.key == .rightArrow else { return .ignored }
            let size = press.modifiers.contains(.shift) ? 5 : 1
            actions.setDelayMs(state.nudgedDelay(by: press.key == .leftArrow ? -size : size))
            return .handled
        }
    }

    /// Surround resets every speaker's trim and delay and clears the
    /// measured flag; Stereo the pair.
    private func reset() {
        guard state.surroundRows != nil else { return actions.reset() }
        actions.resetSurround()
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("TIMING")
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    readoutRow("Delay offset", value: state.delayReadout)
                    nudgeButtons
                }
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
                clickTestButton
                autoCalibrateButton
            }
            calibrationLine
            clickTestMessageLine
            if let latencies = state.reportedLatencies {
                Text(latencies)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var clickTestMessageLine: some View {
        if let message = state.clickTestMessage {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(message)
        }
    }

    private var autoCalibrateButton: some View {
        Button("Auto-calibrate") { actions.autoCalibrate?() }
            .disabled(actions.autoCalibrate == nil || state.calibrationStatus?.isInProgress == true)
            .help(actions.autoCalibrate == nil ? "Needs the Mac's built-in microphone" : "")
    }

    private var clickTestButton: some View {
        Button(state.isClickTestPlaying ? "Stop Click Test" : "Play Click Test",
               action: actions.playClickTest)
            .disabled(!state.isClickTestAvailable)
    }

    // MARK: - Surround

    /// Tallest the per-speaker lists get before they scroll.
    private static let surroundListMaxHeight: CGFloat = 220
    private static let surroundRowHeight: CGFloat = 44
    /// Level rows also carry the speaker volume line.
    private static let surroundLevelRowHeight: CGFloat = 72

    private func surroundList<Row: View>(_ rows: [SurroundTuningRow], rowHeight: CGFloat = surroundRowHeight,
                                         @ViewBuilder row: @escaping (SurroundTuningRow) -> Row) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(rows) { item in
                    row(item)
                }
            }
            .padding(.trailing, 4)
        }
        .frame(height: min(CGFloat(rows.count) * rowHeight, Self.surroundListMaxHeight))
    }

    /// Per-speaker delay, then the click test (SPEC section 13).
    private func surroundTiming(_ rows: [SurroundTuningRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("TIMING")
            surroundList(rows) { row in
                VStack(spacing: 4) {
                    readoutRow(row.label, value: row.offsetReadout)
                    Slider(
                        value: Binding(
                            get: { row.offsetMs },
                            set: { actions.setSurroundOffset(row.uid, $0.rounded()) }),
                        in: SurroundTuningRow.offsetRange)
                        .labelsHidden()
                        .accessibilityLabel("\(row.label) delay")
                        .accessibilityValue(row.offsetReadout)
                }
            }
            HStack(spacing: 8) {
                Text("Delay the speakers that play early.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                clickTestButton
                autoCalibrateButton
            }
            if state.isSurroundTimingMeasured {
                Text("Timing measured with the microphone; distances set level only.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            calibrationLine
            clickTestMessageLine
        }
    }

    private func surroundLevel(_ rows: [SurroundTuningRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("LEVEL")
            surroundList(rows, rowHeight: Self.surroundLevelRowHeight) { row in
                VStack(spacing: 4) {
                    readoutRow(row.label, value: row.trimReadout)
                    Slider(
                        value: Binding(
                            get: { row.trim },
                            set: { actions.setSurroundTrim(row.uid, $0) }),
                        in: 0...1)
                        .labelsHidden()
                        .accessibilityLabel("\(row.label) level")
                        .accessibilityValue(row.trimReadout)
                    if let volume = state.speakerVolume(uid: row.uid) {
                        speakerVolumeLine(volume, title: "Speaker volume")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var calibrationLine: some View {
        switch state.calibrationStatus {
        case .listening, .measuringPair:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(state.calibrationStatus?.progressText ?? "Listening…")
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
            if !state.speakerVolumes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speaker volume")
                        .font(.callout)
                    ForEach(state.speakerVolumes) { row in
                        speakerVolumeLine(row, title: row.label)
                    }
                }
            }
        }
    }

    /// Hardware volume offset for one speaker (SPEC 4a), with a note when
    /// it is held at the speaker's maximum or cannot be raised.
    private func speakerVolumeLine(_ row: SpeakerVolumeRow, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(row.readout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper(
                    "\(row.label) speaker volume",
                    value: Binding(
                        get: { row.offsetDb },
                        set: { actions.setSpeakerVolumeOffset(row.uid, $0) }),
                    in: row.range,
                    step: 1)
                    .labelsHidden()
                    .accessibilityValue(row.readout)
            }
            .font(.callout)
            if let note = row.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Plays the showcase demo so the result can be heard straight away.
    private var demo: some View {
        HStack(spacing: 8) {
            Button(state.demoButtonTitle, action: actions.toggleDemo)
                .disabled(!state.isDemoButtonEnabled)
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

    /// Positive steps delay the right speaker more, negative the left.
    private var nudgeButtons: some View {
        HStack(spacing: 4) {
            ForEach([-5, -1, 1, 5], id: \.self) { step in
                Button(step < 0 ? "\u{2212}\(-step)" : "+\(step)") {
                    actions.setDelayMs(state.nudgedDelay(by: step))
                }
                .accessibilityLabel(Self.nudgeLabel(step))
            }
        }
    }

    static func nudgeLabel(_ step: Int) -> String {
        let unit = abs(step) == 1 ? "millisecond" : "milliseconds"
        let side = step < 0 ? "left" : "right"
        return "Delay \(abs(step)) \(unit) more on the \(side)"
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

#Preview("Surround") {
    TuningSheet(state: SampleStates.tuningSurround)
}

#Preview("Extended, left") {
    TuningSheet(state: TuningState(
        delayMs: -120, isExtendedRange: true, balance: -0.2,
        reportedLatencies: SampleStates.tuning.reportedLatencies))
}
