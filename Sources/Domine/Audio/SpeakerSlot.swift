/// One of the two front speakers by kernel position: `.left` is Device A
/// (the Front Left card), `.right` is Device B (Front Right). It names a
/// speaker, not a stereo channel: with sides swapped, `.left` is still the
/// Front Left speaker.
enum SpeakerSlot: Equatable, Sendable {
    case left
    case right

    var other: SpeakerSlot { self == .left ? .right : .left }
}
