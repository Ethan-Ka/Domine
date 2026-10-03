/// The Stereo / Surround control in the toolbar. Surround is SPEC section 13.
enum RoutingMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case stereo
    case surround

    /// Accepts "quad", the stored value from before Surround replaced Quad,
    /// so saved settings and rooms open in Surround.
    init?(rawValue: String) {
        switch rawValue {
        case "stereo": self = .stereo
        case "surround", "quad": self = .surround
        default: return nil
        }
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .stereo: "Stereo"
        case .surround: "Surround"
        }
    }
}
