import CoreAudio

/// Every Core Audio call in the app goes through this protocol: property
/// reads and writes, listeners, taps, aggregates, and IOProcs.
/// `CoreAudioHAL` is the real implementation; tests use a fake.
protocol AudioHAL: AnyObject, Sendable {
    // MARK: Devices

    func deviceIDs() throws(HALError) -> [AudioObjectID]
    /// The current ID for a UID, or `kAudioObjectUnknown` if no such device exists.
    func deviceID(forUID uid: String) throws(HALError) -> AudioObjectID
    func uid(of device: AudioObjectID) throws(HALError) -> String
    func name(of device: AudioObjectID) throws(HALError) -> String
    func outputChannelCount(of device: AudioObjectID) throws(HALError) -> Int
    func transportType(of device: AudioObjectID) throws(HALError) -> UInt32
    /// Channels per buffer, in buffer order (`kAudioDevicePropertyStreamConfiguration`).
    func streamChannels(of device: AudioObjectID, scope: StreamScope) throws(HALError) -> [Int]
    func nominalSampleRate(of device: AudioObjectID) throws(HALError) -> Double
    func setNominalSampleRate(_ rate: Double, of device: AudioObjectID) throws(HALError)
    /// Device latency, safety offset, and output stream latency, all output scope.
    func outputLatency(of device: AudioObjectID) throws(HALError) -> DeviceLatency
    /// Device latency, safety offset, and largest stream latency in `scope`.
    func latency(of device: AudioObjectID, scope: StreamScope) throws(HALError) -> DeviceLatency
    /// `kAudioDevicePropertyActualSampleRate`: the measured rate while running.
    func actualSampleRate(of device: AudioObjectID) throws(HALError) -> Double
    /// `kAudioDevicePropertyAvailableNominalSampleRates`, as closed ranges.
    func availableNominalSampleRates(of device: AudioObjectID) throws(HALError) -> [ClosedRange<Double>]
    /// `kAudioDevicePropertyBufferFrameSize`: the IO buffer size in frames.
    func bufferFrameSize(of device: AudioObjectID) throws(HALError) -> UInt32
    /// `kAudioStreamPropertyVirtualFormat` of each stream in `scope`, in stream order.
    func streamFormats(of device: AudioObjectID, scope: StreamScope) throws(HALError) -> [AudioStreamBasicDescription]

    // MARK: Hardware volume (SPEC section 4a)

    /// Output-scope elements whose `kAudioDevicePropertyVolumeScalar` can be
    /// set: the main element when it is settable, else every settable channel
    /// element. Empty when the device has no settable volume.
    func volumeElements(of device: AudioObjectID) throws(HALError) -> [AudioObjectPropertyElement]
    /// `kAudioDevicePropertyVolumeScalar`, output scope, 0...1.
    func volume(of device: AudioObjectID, element: AudioObjectPropertyElement) throws(HALError) -> Float
    func setVolume(_ volume: Float, of device: AudioObjectID, element: AudioObjectPropertyElement) throws(HALError)

    func defaultOutputDevice() throws(HALError) -> AudioObjectID
    func setDefaultOutputDevice(_ device: AudioObjectID) throws(HALError)

    /// The handler runs on the main actor each time the property changes.
    func addListener(
        _ property: HALProperty,
        handler: @escaping @MainActor @Sendable () -> Void
    ) throws(HALError) -> HALListenerToken

    // MARK: Process taps

    /// This process's Core Audio process object, or `kAudioObjectUnknown`.
    func ownProcessObject() throws(HALError) -> AudioObjectID
    /// A private stereo global tap of every process except `processes`.
    /// A muting tap silences the tapped audio on its normal output; the
    /// engine's tap mutes, the capture permission probe's does not.
    func createProcessTap(excluding processes: [AudioObjectID], muted: Bool) throws(HALError) -> ProcessTap
    func destroyProcessTap(_ tap: AudioObjectID) throws(HALError)
    func tapFormat(of tap: AudioObjectID) throws(HALError) -> AudioStreamBasicDescription

    // MARK: Aggregate devices

    func createAggregateDevice(_ description: [String: Any]) throws(HALError) -> AudioObjectID
    func destroyAggregateDevice(_ device: AudioObjectID) throws(HALError)

    // MARK: IOProcs

    func createIOProc(
        on device: AudioObjectID,
        proc: AudioDeviceIOProc,
        clientData: UnsafeMutableRawPointer?
    ) throws(HALError) -> IOProcHandle
    /// One flag per input stream of the device, in stream order.
    func setInputStreamUsage(_ enabled: [Bool], for proc: IOProcHandle) throws(HALError)
    func destroyIOProc(_ proc: IOProcHandle) throws(HALError)
    func startDevice(_ proc: IOProcHandle) throws(HALError)
    func stopDevice(_ proc: IOProcHandle) throws(HALError)
}
