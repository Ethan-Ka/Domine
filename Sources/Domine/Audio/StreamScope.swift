import CoreAudio

/// Input or output side of a device's stream configuration.
enum StreamScope: Sendable {
    case input
    case output

    var propertyScope: AudioObjectPropertyScope {
        switch self {
        case .input: kAudioObjectPropertyScopeInput
        case .output: kAudioObjectPropertyScopeOutput
        }
    }
}
