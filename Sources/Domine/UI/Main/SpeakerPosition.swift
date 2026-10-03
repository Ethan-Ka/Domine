/// A place on the stage in Stereo mode. Surround cards are keyed by device
/// UID instead (`SurroundCardInfo`).
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

    /// The fixed positions drawn in `mode`. Surround draws one card per
    /// surround speaker instead, so it has none.
    static func positions(in mode: RoutingMode) -> [SpeakerPosition] {
        mode == .stereo ? [.frontLeft, .frontRight] : []
    }

    var isFront: Bool { self == .frontLeft || self == .frontRight }
    var isLeft: Bool { self == .frontLeft || self == .rearLeft }
}
