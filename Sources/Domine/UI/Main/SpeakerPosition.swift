/// A place on the stage. v1 routes to the front pair only; the rear pair is
/// shown as placeholders until quad mode (SPEC section 11).
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

    var isFront: Bool { self == .frontLeft || self == .frontRight }
    var isLeft: Bool { self == .frontLeft || self == .rearLeft }
}
