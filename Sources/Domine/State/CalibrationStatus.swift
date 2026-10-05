/// The Auto-calibrate line in the Sync & Balance sheet.
enum CalibrationStatus: Equatable, Sendable {
    case listening
    /// Surround (SPEC 12): pair `pair` of `count` is being measured, 1-based.
    case measuringPair(Int, of: Int)
    /// e.g. "Right was 12 ms late. Delay set."
    case done(String)
    case failed(String, offersPrivacySettings: Bool = false)

    /// A run is in progress: the button and the click test are disabled.
    var isInProgress: Bool {
        switch self {
        case .listening, .measuringPair: true
        case .done, .failed: false
        }
    }

    /// "Measuring pair 2 of 4…" while a surround run is in progress.
    var progressText: String? {
        switch self {
        case .listening: "Listening…"
        case .measuringPair(let pair, let count): "Measuring pair \(pair) of \(count)…"
        case .done, .failed: nil
        }
    }
}
