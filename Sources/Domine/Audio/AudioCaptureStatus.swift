/// What Domine knows about the audio capture permission. There is no public
/// API to read the grant, so the only proof is non-zero audio from a tap.
enum AudioCaptureStatus: Equatable, Sendable {
    /// No probe has run and no audio has been seen.
    case unknown
    /// A probe ran and saw only silence: denied, or nothing was playing.
    case notConfirmed
    /// Non-zero tap audio arrived at least once.
    case working
}
