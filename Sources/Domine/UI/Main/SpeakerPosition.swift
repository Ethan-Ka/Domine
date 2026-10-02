/// A place on the stage. Stereo shows the front pair; quad adds the rear
/// pair (SPEC section 11).
enum SpeakerPosition: String, CaseIterable, Identifiable, Sendable {
    case frontLeft
    case frontRight
    case rearLeft
    case rearRight

    var id: Self { self }

    var title: String {
        switch self {
        case .frontLeft: "Front Left"
        case .frontRight: "Front Right"
        case .rearLeft: "Rear Left"
        case .rearRight: "Rear Right"
        }
    }

    /// The positions drawn in `mode`.
    static func positions(in mode: RoutingMode) -> [SpeakerPosition] {
        mode == .quad ? allCases : [.frontLeft, .frontRight]
    }

    var isFront: Bool { self == .frontLeft || self == .frontRight }
    var isLeft: Bool { self == .frontLeft || self == .rearLeft }
}
