import SwiftUI

/// Settings > Advanced: keep-alive tone, timing reference, volume limits,
/// calibration and reconnect timing, and the volume overlay.
struct AdvancedSettingsView: View {
    @Binding var settings: AdvancedSettings
    var clockChoices: [AdvancedClockChoice] = []
    var restoreDefaults: () -> Void = {}

    typealias S = AdvancedSettings

    var body: some View {
        VStack(spacing: 0) {
            Form {
                keepAliveSection
                timingSection
                limitsSection
                calibrationSection
                reconnectSection
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Restore Defaults", action: restoreDefaults)
                    .disabled(settings == AdvancedSettings())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 560, height: 620)
    }

    // MARK: Sections

    private var keepAliveSection: some View {
        Section("Keep speakers from turning off") {
            AdvancedSliderRow(title: "Wait before tone", value: $settings.keepAliveIdleSeconds,
                              range: S.keepAliveIdleRange, step: 0.5, readout: Self.seconds,
                              caption: "How long audio is silent before the tone starts.")
            AdvancedSliderRow(title: "Tone frequency", value: $settings.keepAliveHz,
                              range: S.keepAliveHzRange, step: 1, readout: { "\(Int($0.rounded())) Hz" },
                              caption: "Lower is harder to hear. Raise it if a speaker still turns off.")
            AdvancedSliderRow(title: "Tone level", value: $settings.keepAliveLevelDb,
                              range: S.keepAliveLevelRange, step: 1, readout: Self.dbfs,
                              caption: "Raise it if a speaker still turns off. Lower it if you hear a hum.")
        }
    }

    private var timingSection: some View {
        Section("Timing") {
            VStack(alignment: .leading, spacing: 2) {
                Picker("Timing reference", selection: $settings.clockSpeakerUID) {
                    Text("First speaker (default)").tag(String?.none)
                    ForEach(clockChoices) { choice in
                        Text(choice.title).tag(String?.some(choice.uid))
                    }
                }
                AdvancedCaption(text: "The speaker the others stay in sync with. Pick the one with the steadiest connection.")
            }
        }
    }

    private var limitsSection: some View {
        Section("Limits") {
            AdvancedSliderRow(title: "Maximum volume", value: $settings.maxVolume,
                              range: S.maxVolumeRange, step: 0.05, readout: Self.percent,
                              caption: "Above 100% Domine boosts the sound. Surround stops at 100%.")
            VStack(alignment: .leading, spacing: 2) {
                Picker("Speaker volume offset range", selection: $settings.offsetRangeDb) {
                    ForEach(S.offsetRangeChoices, id: \.self) { db in
                        Text("\u{00B1}\(Int(db)) dB").tag(db)
                    }
                }
                AdvancedCaption(text: "How far each speaker can sit above or below the main volume.")
            }
        }
    }

    private var calibrationSection: some View {
        Section("Calibration") {
            AdvancedSliderRow(title: "Recording length", value: $settings.calibrationRecordSeconds,
                              range: S.calibrationSecondsRange, step: 0.5, readout: Self.seconds,
                              caption: "Longer recordings help in noisy rooms.")
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Extra attempts") {
                    Stepper(value: $settings.calibrationExtraAttempts, in: S.calibrationAttemptsRange) {
                        Text("\(settings.calibrationExtraAttempts)").monospacedDigit()
                    }
                }
                AdvancedCaption(text: "Times to record again when the microphone hears too much or too little.")
            }
            AdvancedSliderRow(title: "Starting test volume", value: $settings.calibrationStartVolume,
                              range: S.calibrationStartVolumeRange, step: 0.05, readout: Self.percent,
                              caption: "Lower it if the first recording is often too loud.")
        }
    }

    private var reconnectSection: some View {
        Section("Reconnect and volume overlay") {
            AdvancedSliderRow(title: "First try after", value: $settings.reconnectFirstDelaySeconds,
                              range: S.reconnectFirstDelayRange, step: 1, readout: Self.seconds)
            AdvancedSliderRow(title: "Try again every", value: $settings.reconnectRetrySeconds,
                              range: S.reconnectRetryRange, step: 5, readout: Self.seconds)
            AdvancedSliderRow(title: "Give up after", value: $settings.reconnectGiveUpMinutes,
                              range: S.reconnectGiveUpRange, step: 1, readout: { "\(Int($0.rounded())) min" })
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Show volume overlay", isOn: $settings.showsVolumeHUD)
                AdvancedCaption(text: "The volume level that appears while you press the volume keys.")
            }
            AdvancedSliderRow(title: "Overlay time", value: $settings.volumeHUDSeconds,
                              range: S.hudSecondsRange, step: 0.5, readout: Self.seconds)
                .disabled(!settings.showsVolumeHUD)
        }
    }

    // MARK: Readouts

    static func seconds(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value)) s" : String(format: "%.1f s", value)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func dbfs(_ value: Double) -> String {
        let db = Int(value.rounded())
        return db < 0 ? "\u{2212}\(-db) dBFS" : "\(db) dBFS"
    }
}

#if DEBUG
#Preview("Advanced") {
    @Previewable @State var settings = AdvancedSettings()
    AdvancedSettingsView(settings: $settings, clockChoices: [
        AdvancedClockChoice(uid: "60-FD-A6-19-4F-2A:output", name: "Left: JBL Grip (4F2A)"),
        AdvancedClockChoice(uid: "60-FD-A6-19-9C-11:output", name: "Right: JBL Grip (9C11)"),
    ])
}
#endif
