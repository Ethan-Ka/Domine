/// Everything the Sync & Balance sheet shows (docs/mockups/Tuning.dc.html).
struct TuningState: Equatable, Sendable {
    /// Signed offset in ms. Positive delays the right speaker, negative the
    /// left (SPEC section 4).
    var delayMs: Int
    var isExtendedRange: Bool
    /// -1 (all left) ... 0 (centered) ... 1 (all right).
    var balance: Double
    /// e.g. "macOS reports 182 ms (Left) and 178 ms (Right). ..."
    var reportedLatencies: String?

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
