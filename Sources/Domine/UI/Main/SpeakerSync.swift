/// Which speaker the others wait for, shown on its card and connector
/// (docs/IDEAS.md, visual 1). Delays are whole milliseconds.
enum SpeakerSync: Equatable, Sendable {
    /// No added delay; the other speakers line up with this one.
    case reference
    /// Held back by this many milliseconds.
    case delayed(ms: Int)

    /// The card's detail line.
    var text: String {
        switch self {
        case .reference: "Timing reference"
        case .delayed(let ms): "Delayed \(ms) ms"
        }
    }

    /// The small label beside the connector, only for a delayed speaker.
    var connectorLabel: String? {
        switch self {
        case .reference: nil
        case .delayed(let ms): "+\(ms) ms"
        }
    }

    /// Stereo: a positive pair delay holds back position B (Front Right),
    /// a negative one position A (Front Left). Zero shows nothing.
    static func stereo(delayMs: Float) -> (a: SpeakerSync?, b: SpeakerSync?) {
        let ms = Int(delayMs.rounded())
        if ms > 0 { return (.reference, .delayed(ms: ms)) }
        if ms < 0 { return (.delayed(ms: -ms), .reference) }
        return (nil, nil)
    }

    /// Surround: each speaker's total delay by UID. The ones at zero are the
    /// reference. When every speaker is at zero, nothing is shown.
    static func surround(delaysMs: [String: Float]) -> [String: SpeakerSync] {
        let rounded = delaysMs.mapValues { max(Int($0.rounded()), 0) }
        guard rounded.values.contains(where: { $0 > 0 }) else { return [:] }
        return rounded.mapValues { $0 > 0 ? .delayed(ms: $0) : .reference }
    }
}
