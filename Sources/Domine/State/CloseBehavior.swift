/// What happens to audio when the main window closes (SPEC section 6a).
enum CloseBehavior: String, Sendable {
    case keepPlaying
    case stopPlaying
}
