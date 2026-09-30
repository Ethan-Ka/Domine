/// What the Sync & Balance sheet can ask the model to do.
struct TuningActions: Sendable {
    var setDelayMs: @MainActor @Sendable (Int) -> Void = { _ in }
    var setExtendedRange: @MainActor @Sendable (Bool) -> Void = { _ in }
    var setBalance: @MainActor @Sendable (Double) -> Void = { _ in }
    var playClickTest: @MainActor @Sendable () -> Void = {}
    /// Mic-based calibration (SPEC section 12). The button stays disabled
    /// while this is nil.
    var autoCalibrate: (@MainActor @Sendable () -> Void)? = nil
    var reset: @MainActor @Sendable () -> Void = {}
    var done: @MainActor @Sendable () -> Void = {}

    static let none = TuningActions()
}
