/// What one Auto-calibrate run replaced, so Undo Calibration can put it back.
/// Kept until the sheet closes or the user changes timing or level by hand.
enum CalibrationUndo: Equatable, Sendable {
    /// Stereo: the pair's delay and balance before the run.
    case stereo(delayMs: Float, balance: Float)
    /// Surround: every offset and trim, and the measured marks, before the run.
    case surround(offsetsMs: [String: Float], trims: [String: Float],
                  timingMeasured: Bool, levelMeasured: Bool)
}
