/// The Auto-calibrate line in the Sync & Balance sheet.
enum CalibrationStatus: Equatable, Sendable {
    case listening
    /// e.g. "Right was 12 ms late. Delay set."
    case done(String)
    case failed(String, offersPrivacySettings: Bool = false)
}
