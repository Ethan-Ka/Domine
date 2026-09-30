/// The Stereo / Quad control in the toolbar. Quad is v2 (SPEC section 11).
enum RoutingMode: String, CaseIterable, Identifiable, Sendable {
    case stereo
    case quad

    var id: Self { self }

    var title: String {
        switch self {
        case .stereo: "Stereo"
        case .quad: "Quad"
        }
    }
}
