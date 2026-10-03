/// The showcase demo as the main window shows it (SPEC section 14).
struct DemoState: Equatable, Sendable {
    var isPlaying = false
    /// Where the sound the listener should follow is, in degrees (0 ahead,
    /// positive to the right).
    var azimuth: Double = 0
    /// e.g. "Calibration"; nil while idle.
    var sectionTitle: String?
    /// Routing with at least two speakers present. "Stop Demo" stays
    /// enabled while playing regardless.
    var canPlay = true

    var isButtonEnabled: Bool { isPlaying || canPlay }

    var buttonTitle: String { isPlaying ? "Stop Demo" : "Play Demo" }

    /// Toolbar status while playing, e.g. "Demo: Orbit".
    var statusLine: String? {
        guard isPlaying else { return nil }
        return "Demo: \(sectionTitle ?? "Playing")"
    }
}
