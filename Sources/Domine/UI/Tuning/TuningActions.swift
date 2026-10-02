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

    static let none = TuningActions()
}
