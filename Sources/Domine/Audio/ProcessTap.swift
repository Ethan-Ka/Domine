import CoreAudio

/// A process tap created through the HAL. `uid` is what the aggregate's tap list refers to.
struct ProcessTap: Equatable, Sendable {
    let id: AudioObjectID
    let uid: String
}
