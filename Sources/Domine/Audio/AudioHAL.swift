import CoreAudio

/// Every Core Audio property read, write, and listener in the app goes through
/// this protocol. `CoreAudioHAL` is the real implementation; tests use a fake.
protocol AudioHAL: AnyObject, Sendable {
    func deviceIDs() throws(HALError) -> [AudioObjectID]
    func uid(of device: AudioObjectID) throws(HALError) -> String
    func name(of device: AudioObjectID) throws(HALError) -> String
    func outputChannelCount(of device: AudioObjectID) throws(HALError) -> Int
    func transportType(of device: AudioObjectID) throws(HALError) -> UInt32

    func defaultOutputDevice() throws(HALError) -> AudioObjectID
    func setDefaultOutputDevice(_ device: AudioObjectID) throws(HALError)

    /// The handler runs on the main actor each time the property changes.
    func addListener(
        _ property: HALProperty,
        handler: @escaping @MainActor @Sendable () -> Void
    ) throws(HALError) -> HALListenerToken
}
