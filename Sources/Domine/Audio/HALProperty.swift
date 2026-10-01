import CoreAudio

/// Properties the app can listen to.
enum HALProperty: Hashable, Sendable {
    case devices
    case defaultOutputDevice
    case name(AudioObjectID)
    case isAlive(AudioObjectID)
    /// `kAudioDeviceProcessorOverload`: fires when an IO cycle ran late.
    case processorOverload(AudioObjectID)
    case nominalSampleRate(AudioObjectID)

    var object: AudioObjectID {
        switch self {
        case .devices, .defaultOutputDevice: AudioObjectID(kAudioObjectSystemObject)
        case .name(let id), .isAlive(let id), .processorOverload(let id), .nominalSampleRate(let id): id
        }
    }

    var address: AudioObjectPropertyAddress {
        let selector: AudioObjectPropertySelector = switch self {
        case .devices: kAudioHardwarePropertyDevices
        case .defaultOutputDevice: kAudioHardwarePropertyDefaultOutputDevice
        case .name: kAudioObjectPropertyName
        case .isAlive: kAudioDevicePropertyDeviceIsAlive
        case .processorOverload: kAudioDeviceProcessorOverload
        case .nominalSampleRate: kAudioDevicePropertyNominalSampleRate
        }
        return AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
