/// Everything the Sync & Balance sheet shows (docs/mockups/Tuning.dc.html).
struct TuningState: Equatable, Sendable {
    /// Signed offset in ms, in 0.5 ms steps. Positive delays the right
    /// speaker, negative the left (SPEC section 4).
    var delayMs: Double
    /// -1 (all left) ... 0 (centered) ... 1 (all right).
    var balance: Double
    /// e.g. "Reported latency: left 182 ms, right 176 ms".
    var reportedLatencies: String?
    /// Clicks are playing; the button reads Stop Click Test.
    var isClickTestPlaying = false
    /// False while routing is starting or stopping.
    var isClickTestAvailable = true
    /// Why the click test could not start, in one short line.
    var clickTestMessage: String?
    /// Auto-calibrate progress or result; nil before a run.
    var calibrationStatus: CalibrationStatus?
    /// Why Auto-calibrate cannot run, shown as a line in the sheet; nil when it can.
    var calibrationUnavailableReason: String?
    /// The last run can be undone: shows Undo Calibration.
    var canUndoCalibration = false
    /// Step sizes for the nudge buttons and arrow keys.
    var nudgeSteps: DelayNudgeSteps = .normal
    /// The showcase demo is playing; the button reads Stop Demo.
    var isDemoPlaying = false
    /// The demo's current part, e.g. "Orbit", shown under the button.
    var demoSectionTitle: String?
    /// Routing with at least two speakers present.
    var canPlayDemo = true
    /// Surround mode: one row per speaker, replacing the pair's delay offset
    /// and balance. Nil in Stereo.
    var surroundRows: [SurroundTuningRow]?
    /// Surround: the offsets were measured with the microphone (SPEC 13.4).
    var isSurroundTimingMeasured = false
    /// Each speaker's hardware volume offset (SPEC 4a), in row order.
    var speakerVolumes: [SpeakerVolumeRow] = []
    /// Each speaker's role, in row order. Empty hides the role controls.
    var speakerRoles: [SpeakerRoleRow] = []
    /// Crossover every satellite and subwoofer of the setup shares, 40...200 Hz.
    var crossoverHz: Double = Double(SpeakerRole.defaultCrossoverHz)

    var crossoverReadout: String { SpeakerRole.crossoverReadout(crossoverHz) }
    /// The crossover slider only matters once a speaker is not full range.
    var isCrossoverEnabled: Bool { speakerRoles.contains { $0.role != .fullRange } }

    func speakerVolume(uid: String) -> SpeakerVolumeRow? {
        speakerVolumes.first { $0.uid == uid }
    }

    /// Surround: the trims were measured with the microphone (SPEC 13.4).
    var isSurroundLevelMeasured = false

    /// The Sync & Balance note on what the microphone measured and what
    /// distances still set, or nil when nothing was measured.
    var surroundMeasuredNote: String? {
        switch (isSurroundTimingMeasured, isSurroundLevelMeasured) {
        case (true, true): "Timing and levels measured with the microphone."
        case (true, false): "Timing measured with the microphone; distances set level only."
        case (false, true): "Levels measured with the microphone; distances set timing only."
        case (false, false): nil
        }
    }

    var isDemoButtonEnabled: Bool { isDemoPlaying || canPlayDemo }

    var demoButtonTitle: String { isDemoPlaying ? "Stop Demo" : "Play Demo" }

    /// One line under the demo button while it plays.
    var demoCaption: String? {
        guard isDemoPlaying else { return nil }
        return "Now playing: \(demoSectionTitle ?? "Demo")"
    }

    /// One range for every pair: wide enough for mixed speaker models.
    static let delayRange: ClosedRange<Double> = -300...300

    /// Before the first run, so the button explains itself.
    static let calibrationCaption = "Uses the Mac's microphone to line up the speakers. Put the Mac where you sit."

    var delayReadout: String { Self.delayReadout(delayMs) }

    /// The delay after nudging by `step` ms, kept inside the current range.
    func nudgedDelay(by step: Double) -> Double {
        Self.nudge(delayMs, by: step, in: Self.delayRange)
    }

    static func nudge(_ ms: Double, by step: Double, in range: ClosedRange<Double>) -> Double {
        min(max(roundedDelay(ms + step), range.lowerBound), range.upperBound)
    }

    /// Nearest 0.5 ms.
    static func roundedDelay(_ ms: Double) -> Double {
        (ms * 2).rounded() / 2
    }

    /// "4" or "4.5": whole numbers without a decimal point.
    static func msText(_ ms: Double) -> String {
        let value = roundedDelay(ms)
        return value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }

    var balanceReadout: String { Self.balanceReadout(balance) }

    static func delayReadout(_ ms: Double) -> String {
        let value = roundedDelay(ms)
        if value > 0 { return "Right +\(msText(value)) ms" }
        if value < 0 { return "Left +\(msText(-value)) ms" }
        return "In sync"
    }

    static func balanceReadout(_ balance: Double) -> String {
        let percent = Int((min(max(balance, -1), 1) * 100).rounded())
        if percent > 0 { return "Right \(percent)%" }
        if percent < 0 { return "Left \(-percent)%" }
        return "Centered"
    }
}
