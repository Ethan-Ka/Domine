/// What the Sync & Balance sheet can ask the model to do.
struct TuningActions: Sendable {
    /// Rounded to 0.5 ms and clamped to -300...300 by the model.
    var setDelayMs: @MainActor @Sendable (Double) -> Void = { _ in }
    var setBalance: @MainActor @Sendable (Double) -> Void = { _ in }
    var playClickTest: @MainActor @Sendable () -> Void = {}
    /// Mic-based calibration (SPEC section 12). Nil without a built-in
    /// microphone, which keeps the button disabled.
    var autoCalibrate: (@MainActor @Sendable () -> Void)? = nil
    /// Puts back what the last run replaced. Nil when there is nothing to undo.
    var undoCalibration: (@MainActor @Sendable () -> Void)? = nil
    /// A hand edit in Surround: Undo Calibration is no longer offered.
    var discardCalibrationUndo: @MainActor @Sendable () -> Void = {}
    var setNudgeSteps: @MainActor @Sendable (DelayNudgeSteps) -> Void = { _ in }
    var openMicrophoneSettings: @MainActor @Sendable () -> Void = {}
    var reset: @MainActor @Sendable () -> Void = {}
    /// Surround: every trim and offset back to default, measured flag cleared.
    var resetSurround: @MainActor @Sendable () -> Void = {}
    var done: @MainActor @Sendable () -> Void = {}
    /// "Play Demo" / "Stop Demo".
    var toggleDemo: @MainActor @Sendable () -> Void = {}
    /// Surround: one speaker's level trim (0...1) and delay (0...300 ms).
    var setSurroundTrim: @MainActor @Sendable (_ uid: String, _ trim: Double) -> Void = { _, _ in }
    var setSurroundOffset: @MainActor @Sendable (_ uid: String, _ ms: Double) -> Void = { _, _ in }

    /// One speaker's role, and the crossover frequency in Hz.
    var setSpeakerRole: @MainActor @Sendable (_ uid: String, _ role: SpeakerRole) -> Void = { _, _ in }
    var setCrossoverHz: @MainActor @Sendable (_ hz: Double) -> Void = { _ in }

    /// One speaker's hardware volume offset in dB.
    var setSpeakerVolumeOffset: @MainActor @Sendable (_ uid: String, _ db: Double) -> Void = { _, _ in }

    static let none = TuningActions()
}
