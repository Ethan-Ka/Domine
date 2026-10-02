/// One speaker's row in Sync & Balance in Surround mode.
struct SurroundTuningRow: Identifiable, Equatable, Sendable {
    /// Device UID.
    var uid: String
    /// Direction title like "Front Left".
    var title: String
    /// Four characters from the UID that tell two "JBL Grip"s apart.
    var suffix: String?
    /// Level trim, 0...1.
    var trim: Double
    /// Delay added to this speaker, 0...300 ms.
    var offsetMs: Double

    var id: String { uid }

    static let offsetRange: ClosedRange<Double> = 0...300

    var label: String { [title, suffix].compactMap { $0 }.joined(separator: " ") }
    var trimReadout: String { "\(Int((min(max(trim, 0), 1) * 100).rounded()))%" }
    var offsetReadout: String {
        let ms = Int(offsetMs.rounded())
        return ms == 0 ? "No delay" : "+\(ms) ms"
    }
}
