/// What the Sync & Balance sheet can ask the model to do.
struct TuningActions: Sendable {
    var setDelayMs: @MainActor @Sendable (Int) -> Void = { _ in }
    var setExtendedRange: @MainActor @Sendable (Bool) -> Void = { _ in }
    var setBalance: @MainActor @Sendable (Double) -> Void = { _ in }
    var playClickTest: @MainActor @Sendable () -> Void = {}
    /// Mic-based calibration (SPEC section 12). Nil without a built-in
    /// microphone, which keeps the button disabled.
    var autoCalibrate: (@MainActor @Sendable () -> Void)? = nil
    var openMicrophoneSettings: @MainActor @Sendable () -> Void = {}
    var reset: @MainActor @Sendable () -> Void = {}
    var done: @MainActor @Sendable () -> Void = {}
    /// "Play Demo" / "Stop Demo".
    var toggleDemo: @MainActor @Sendable () -> Void = {}
    /// Surround: one speaker's level trim (0...1) and delay (0...300 ms).
    var setSurroundTrim: @MainActor @Sendable (_ uid: String, _ trim: Double) -> Void = { _, _ in }
    var setSurroundOffset: @MainActor @Sendable (_ uid: String, _ ms: Double) -> Void = { _, _ in }

    static let none = TuningActions()
}
