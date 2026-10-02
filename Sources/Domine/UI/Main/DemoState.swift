/// The showcase demo as the main window shows it (SPEC section 14).
struct DemoState: Equatable, Sendable {
    var isPlaying = false
    /// Where the sound the listener should follow is, in degrees (0 ahead,
    /// positive to the right).
    var azimuth: Double = 0
    /// e.g. "Roll call"; nil while idle.
    var sectionTitle: String?

    var buttonTitle: String { isPlaying ? "Stop Demo" : "Play Demo" }

    /// Toolbar status while playing, e.g. "Demo: Orbit".
    var statusLine: String? {
        guard isPlaying else { return nil }
        return "Demo: \(sectionTitle ?? "Playing")"
    }
}
