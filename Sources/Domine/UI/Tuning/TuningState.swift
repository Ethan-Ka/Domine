/// Everything the Sync & Balance sheet shows (docs/mockups/Tuning.dc.html).
struct TuningState: Equatable, Sendable {
    /// Signed offset in ms. Positive delays the right speaker, negative the
    /// left (SPEC section 4).
    var delayMs: Int
    var isExtendedRange: Bool
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

    var isDemoButtonEnabled: Bool { isDemoPlaying || canPlayDemo }

    var demoButtonTitle: String { isDemoPlaying ? "Stop Demo" : "Play Demo" }

    /// One line under the demo button while it plays.
    var demoCaption: String? {
        guard isDemoPlaying else { return nil }
        return "Now playing: \(demoSectionTitle ?? "Demo")"
    }

    static let normalRange = -50...50
    static let extendedRange = -300...300

    var delayRange: ClosedRange<Int> {
        isExtendedRange ? Self.extendedRange : Self.normalRange
    }

    var delayReadout: String { Self.delayReadout(delayMs) }
    var balanceReadout: String { Self.balanceReadout(balance) }

    static func delayReadout(_ ms: Int) -> String {
        if ms > 0 { return "Right +\(ms) ms" }
        if ms < 0 { return "Left +\(-ms) ms" }
        return "In sync"
    }

    static func balanceReadout(_ balance: Double) -> String {
        let percent = Int((min(max(balance, -1), 1) * 100).rounded())
        if percent > 0 { return "Right \(percent)%" }
        if percent < 0 { return "Left \(-percent)%" }
        return "Centered"
    }
}
