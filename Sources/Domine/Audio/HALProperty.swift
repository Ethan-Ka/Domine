import CoreAudio

/// Properties the app can listen to.
enum HALProperty: Hashable, Sendable {
    case devices
    case defaultOutputDevice
    case name(AudioObjectID)
    case isAlive(AudioObjectID)
    /// `kAudioDevicePropertyVolumeScalar` on one output-scope element.
    case volume(AudioObjectID, element: AudioObjectPropertyElement)
    /// `kAudioDeviceProcessorOverload`: fires when an IO cycle ran late.
    case processorOverload(AudioObjectID)
    case nominalSampleRate(AudioObjectID)
    /// `kAudioDevicePropertyMute`, output scope, main element.
    case mute(AudioObjectID)

    var object: AudioObjectID {
        switch self {
        case .devices, .defaultOutputDevice: AudioObjectID(kAudioObjectSystemObject)
        case .name(let id), .isAlive(let id), .volume(let id, _), .processorOverload(let id), .nominalSampleRate(let id), .mute(let id): id
        }
    }

    var address: AudioObjectPropertyAddress {
        switch self {
        case .devices: Self.global(kAudioHardwarePropertyDevices)
        case .defaultOutputDevice: Self.global(kAudioHardwarePropertyDefaultOutputDevice)
        case .name: Self.global(kAudioObjectPropertyName)
        case .isAlive: Self.global(kAudioDevicePropertyDeviceIsAlive)
        case .processorOverload: Self.global(kAudioDeviceProcessorOverload)
        case .nominalSampleRate: Self.global(kAudioDevicePropertyNominalSampleRate)
        case .mute:
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
        case .volume(_, let element):
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element)
        }
    }

    private static func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
