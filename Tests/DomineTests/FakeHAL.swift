import CoreAudio
import Foundation
@testable import Domine

/// In-memory HAL. Devices get a fresh `AudioObjectID` each time they are added,
/// like real devices after a reconnect. Taps, aggregates, and IOProcs are
/// simulated; every call that creates, destroys, or changes something is
/// recorded in `ops`.
final class FakeHAL: AudioHAL, @unchecked Sendable {
    struct Device {
        var uid: String
        var name: String
        var outputChannels: Int = 2
        var transportType: UInt32 = kAudioDeviceTransportTypeBluetooth
        /// Channels per output buffer. Defaults to one buffer of `outputChannels`.
        var outputStreams: [Int]? = nil
        var inputStreams: [Int] = []
        var sampleRate: Double = 48_000
        var latency = DeviceLatency()
        /// Settable output volume per element. The default matches a JBL
        /// Grip: no main element, channels 1 and 2 only. Empty means the
        /// device has no settable volume.
        var volumes: [AudioObjectPropertyElement: Float] = [1: 0.5, 2: 0.5]

        var outputLayout: [Int] { outputStreams ?? (outputChannels > 0 ? [outputChannels] : []) }
    }

    enum Op: Equatable {
        case setSampleRate(uid: String)
        case createTap(excluding: [AudioObjectID])
        case destroyTap
        case createAggregate
        case destroyAggregate
        case createIOProc
        case setStreamUsage([Bool])
        case start
        case stop
        case destroyIOProc
    }

    /// Calls that can be made to fail through `failures`.
    enum FailPoint: Hashable, CaseIterable {
        case setSampleRate, ownProcess, createTap, tapFormat, createAggregate,
             aggregateStreams, createIOProc, setStreamUsage, start
    }

    struct IOProc {
        let proc: AudioDeviceIOProc
        let clientData: UnsafeMutableRawPointer?
    }

    private let lock = NSLock()
    private var devices: [AudioObjectID: Device] = [:]
    private var order: [AudioObjectID] = []
    private var nextID: AudioObjectID = 100
    private var defaultOutput: AudioObjectID = kAudioObjectUnknown
    private var listeners: [UUID: (HALProperty, @MainActor @Sendable () -> Void)] = [:]
    private var _ops: [Op] = []
    private var _tapMuteFlags: [Bool] = []
    private var taps: [AudioObjectID: String] = [:]
    private var aggregates: [AudioObjectID: [String: Any]] = [:]
    private var ioProcs: [IOProcHandle: IOProc] = [:]
    private var running: Set<IOProcHandle> = []
    private var aggregateStreamReads = 0
    private var _volumeWrites: [VolumeWrite] = []
    private var _defaultOutputWrites: [String] = []

    struct VolumeWrite: Equatable {
        let uid: String
        let element: AudioObjectPropertyElement
        let volume: Float
    }

    /// Status returned by the next read of any device property. Cleared after use.
    var failNextRead: OSStatus?
    /// Calls that fail with the given status.
    var failures: [FailPoint: OSStatus] = [:]
    var ownProcess: AudioObjectID = 42
    /// The tap's input streams inside an aggregate (one interleaved stereo stream).
    var tapStreams: [Int] = [2]
    /// For this many layout reads (output plus input) a new aggregate reports no streams,
    /// as if it had not finished publishing them.
    var aggregateStreamsHiddenForAttempts = 0
    /// Replaces the aggregate's reported output streams.
    var aggregateOutputOverride: [Int]?

    // MARK: - Test controls

    @MainActor @discardableResult
    func add(_ device: Device) -> AudioObjectID {
        let id = lock.withLock { insert(device) }
        fire(.devices)
        return id
    }

    @MainActor
    func remove(uid: String) {
        let removed: AudioObjectID? = lock.withLock {
            guard let id = devices.first(where: { $0.value.uid == uid })?.key else { return nil }
            devices[id] = nil
            order.removeAll { $0 == id }
            return id
        }
        guard let removed else { return }
        fire(.isAlive(removed))
        fire(.devices)
    }

    @MainActor
    func rename(uid: String, to name: String) {
        let id: AudioObjectID? = lock.withLock {
            guard let id = devices.first(where: { $0.value.uid == uid })?.key else { return nil }
            devices[id]?.name = name
            return id
        }
        if let id { fire(.name(id)) }
    }

    @MainActor
    func setDefault(uid: String) {
        lock.withLock {
            defaultOutput = devices.first { $0.value.uid == uid }?.key ?? kAudioObjectUnknown
        }
        fire(.defaultOutputDevice)
    }

    /// Changes a device's volume from outside Domine, like the + button on a
    /// Grip, and notifies listeners for every element unless `notify` is false.
    @MainActor
    func pressVolume(uid: String, to volume: Float, notify: Bool = true) {
        let changed: (AudioObjectID, [AudioObjectPropertyElement])? = lock.withLock {
            guard let id = devices.first(where: { $0.value.uid == uid })?.key,
                  let elements = devices[id]?.volumes.keys else { return nil }
            for element in elements { devices[id]?.volumes[element] = volume }
            return (id, elements.sorted())
        }
        guard notify, let (id, elements) = changed else { return }
        elements.forEach { fire(.volume(id, element: $0)) }
    }

    /// The device's volume on each element, keyed by element.
    func volumes(uid: String) -> [AudioObjectPropertyElement: Float] {
        lock.withLock { devices.values.first { $0.uid == uid }?.volumes ?? [:] }
    }

    /// Every volume write Domine made, in order.
    var volumeWrites: [VolumeWrite] { lock.withLock { _volumeWrites } }
    func clearVolumeWrites() { lock.withLock { _volumeWrites = [] } }

    /// UIDs Domine made the default output, in order.
    var defaultOutputWrites: [String] { lock.withLock { _defaultOutputWrites } }

    var defaultOutputUID: String? {
        lock.withLock { devices[defaultOutput]?.uid }
    }

    func id(forUID uid: String) -> AudioObjectID? {
        lock.withLock { devices.first { $0.value.uid == uid }?.key }
    }

    var listenerCount: Int { lock.withLock { listeners.count } }
    var ops: [Op] { lock.withLock { _ops } }
    /// The `muted` argument of every tap created, in order.
    var tapMuteFlags: [Bool] { lock.withLock { _tapMuteFlags } }
    var liveTapCount: Int { lock.withLock { taps.count } }
    var liveAggregateCount: Int { lock.withLock { aggregates.count } }
    var liveIOProcCount: Int { lock.withLock { ioProcs.count } }
    var isRunning: Bool { lock.withLock { !running.isEmpty } }
    var lastAggregateDescription: [String: Any]? {
        lock.withLock { aggregates.values.first }
    }
    func sampleRate(uid: String) -> Double? {
        lock.withLock { devices.values.first { $0.uid == uid }?.sampleRate }
    }

    /// Runs one IOProc cycle on the running aggregate, as the HAL would.
    func render(input: FakeBufferList, output: FakeBufferList) {
        guard let (handle, proc) = lock.withLock({ () -> (IOProcHandle, IOProc)? in
            guard let handle = running.first, let proc = ioProcs[handle] else { return nil }
            return (handle, proc)
        }) else { return }
        var now = AudioTimeStamp(), inTime = AudioTimeStamp(), outTime = AudioTimeStamp()
        _ = proc.proc(handle.device, &now, input.pointer, &inTime, output.pointer, &outTime, proc.clientData)
    }

    @MainActor
    private func fire(_ property: HALProperty) {
        let handlers = lock.withLock { listeners.values.filter { $0.0 == property }.map(\.1) }
        handlers.forEach { $0() }
    }

    /// `NSLock.withLock` with a typed throw.
    private func locked<T>(_ body: () throws(HALError) -> T) throws(HALError) -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Internals (call with the lock held)

    private func insert(_ device: Device) -> AudioObjectID {
        let id = nextID
        nextID += 1
        devices[id] = device
        order.append(id)
        return id
    }

    private func fail(_ point: FailPoint, _ operation: String, selector: AudioObjectPropertySelector = 0) throws(HALError) {
        if let status = failures[point] { throw HALError(status, operation, selector: selector) }
    }

    private func device(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws(HALError) -> Device {
        lock.lock()
        defer { lock.unlock() }
        if let status = failNextRead {
            failNextRead = nil
            throw HALError(status, "AudioObjectGetPropertyData", selector: selector)
        }
        guard let d = devices[id] else {
            throw HALError(kAudioHardwareBadObjectError, "AudioObjectGetPropertyData", selector: selector)
        }
        return d
    }

    // MARK: - AudioHAL: devices

    func deviceIDs() throws(HALError) -> [AudioObjectID] { lock.withLock { order } }
    func deviceID(forUID uid: String) throws(HALError) -> AudioObjectID {
        id(forUID: uid) ?? kAudioObjectUnknown
    }
    func uid(of device: AudioObjectID) throws(HALError) -> String {
        try self.device(device, kAudioDevicePropertyDeviceUID).uid
    }
    func name(of device: AudioObjectID) throws(HALError) -> String {
        try self.device(device, kAudioObjectPropertyName).name
    }
    func outputChannelCount(of device: AudioObjectID) throws(HALError) -> Int {
        try self.device(device, kAudioDevicePropertyStreamConfiguration).outputLayout.reduce(0, +)
    }
    func transportType(of device: AudioObjectID) throws(HALError) -> UInt32 {
        try self.device(device, kAudioDevicePropertyTransportType).transportType
    }

    func streamChannels(of device: AudioObjectID, scope: StreamScope) throws(HALError) -> [Int] {
        let d = try self.device(device, kAudioDevicePropertyStreamConfiguration)
        return try locked { () throws(HALError) -> [Int] in
            guard aggregates[device] != nil else {
                return scope == .output ? d.outputLayout : d.inputStreams
            }
            try fail(.aggregateStreams, "AudioObjectGetPropertyData", selector: kAudioDevicePropertyStreamConfiguration)
            aggregateStreamReads += 1
            if aggregateStreamReads <= aggregateStreamsHiddenForAttempts * 2 { return [] }
            if scope == .output, let aggregateOutputOverride { return aggregateOutputOverride }
            return scope == .output ? d.outputLayout : d.inputStreams
        }
    }

    func nominalSampleRate(of device: AudioObjectID) throws(HALError) -> Double {
        try self.device(device, kAudioDevicePropertyNominalSampleRate).sampleRate
    }

    func outputLatency(of device: AudioObjectID) throws(HALError) -> DeviceLatency {
        try self.device(device, kAudioDevicePropertyLatency).latency
    }

    func setNominalSampleRate(_ rate: Double, of device: AudioObjectID) throws(HALError) {
        let d = try self.device(device, kAudioDevicePropertyNominalSampleRate)
        try locked { () throws(HALError) in
            _ops.append(.setSampleRate(uid: d.uid))
            try fail(.setSampleRate, "AudioObjectSetPropertyData", selector: kAudioDevicePropertyNominalSampleRate)
            devices[device]?.sampleRate = rate
        }
    }

    func volumeElements(of device: AudioObjectID) throws(HALError) -> [AudioObjectPropertyElement] {
        try self.device(device, kAudioDevicePropertyVolumeScalar).volumes.keys.sorted()
    }

    func volume(of device: AudioObjectID, element: AudioObjectPropertyElement) throws(HALError) -> Float {
        let d = try self.device(device, kAudioDevicePropertyVolumeScalar)
        guard let volume = d.volumes[element] else {
            throw HALError(kAudioHardwareUnknownPropertyError, "AudioObjectGetPropertyData", selector: kAudioDevicePropertyVolumeScalar)
        }
        return volume
    }

    /// Like the real HAL, a write notifies listeners, including Domine's own.
    func setVolume(_ volume: Float, of device: AudioObjectID, element: AudioObjectPropertyElement) throws(HALError) {
        try locked { () throws(HALError) in
            guard let d = devices[device], d.volumes[element] != nil else {
                throw HALError(kAudioHardwareUnknownPropertyError, "AudioObjectSetPropertyData", selector: kAudioDevicePropertyVolumeScalar)
            }
            devices[device]?.volumes[element] = volume
            _volumeWrites.append(VolumeWrite(uid: d.uid, element: element, volume: volume))
        }
        MainActor.assumeIsolated { fire(.volume(device, element: element)) }
    }

    func defaultOutputDevice() throws(HALError) -> AudioObjectID { lock.withLock { defaultOutput } }
    func setDefaultOutputDevice(_ device: AudioObjectID) throws(HALError) {
        try locked { () throws(HALError) in
            guard let d = devices[device] else {
                throw HALError(kAudioHardwareBadDeviceError, "AudioObjectSetPropertyData", selector: kAudioHardwarePropertyDefaultOutputDevice)
            }
            defaultOutput = device
            _defaultOutputWrites.append(d.uid)
        }
        MainActor.assumeIsolated { fire(.defaultOutputDevice) }
    }

    func addListener(
        _ property: HALProperty,
        handler: @escaping @MainActor @Sendable () -> Void
    ) throws(HALError) -> HALListenerToken {
        let key = UUID()
        lock.withLock { listeners[key] = (property, handler) }
        return HALListenerToken { [weak self] in
            guard let self else { return }
            self.lock.withLock { _ = self.listeners.removeValue(forKey: key) }
        }
    }

    // MARK: - AudioHAL: taps

    func ownProcessObject() throws(HALError) -> AudioObjectID {
        try locked { () throws(HALError) -> AudioObjectID in
            try fail(.ownProcess, "AudioObjectGetPropertyData", selector: kAudioHardwarePropertyTranslatePIDToProcessObject)
            return ownProcess
        }
    }

    func createProcessTap(excluding processes: [AudioObjectID], muted: Bool) throws(HALError) -> ProcessTap {
        try locked { () throws(HALError) -> ProcessTap in
            try fail(.createTap, "AudioHardwareCreateProcessTap")
            _ops.append(.createTap(excluding: processes))
            _tapMuteFlags.append(muted)
            let id = nextID
            nextID += 1
            let uid = "tap-\(id)"
            taps[id] = uid
            return ProcessTap(id: id, uid: uid)
        }
    }

    func destroyProcessTap(_ tap: AudioObjectID) throws(HALError) {
        try locked { () throws(HALError) in
            guard taps.removeValue(forKey: tap) != nil else {
                throw HALError(kAudioHardwareBadObjectError, "AudioHardwareDestroyProcessTap")
            }
            _ops.append(.destroyTap)
        }
    }

    func tapFormat(of tap: AudioObjectID) throws(HALError) -> AudioStreamBasicDescription {
        try locked { () throws(HALError) -> AudioStreamBasicDescription in
            try fail(.tapFormat, "AudioObjectGetPropertyData", selector: kAudioTapPropertyFormat)
            return AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        }
    }

    // MARK: - AudioHAL: aggregates

    /// Builds the aggregate's streams from its sub-devices (in list order)
    /// followed by its taps, like the real HAL.
    func createAggregateDevice(_ description: [String: Any]) throws(HALError) -> AudioObjectID {
        try locked { () throws(HALError) -> AudioObjectID in
            try fail(.createAggregate, "AudioHardwareCreateAggregateDevice")
            _ops.append(.createAggregate)
            let subUIDs = (description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? [])
                .compactMap { $0[kAudioSubDeviceUIDKey] as? String }
            let subs = subUIDs.compactMap { uid in devices.values.first { $0.uid == uid } }
            let tapCount = (description[kAudioAggregateDeviceTapListKey] as? [[String: Any]] ?? []).count
            let aggregate = Device(
                uid: description[kAudioAggregateDeviceUIDKey] as? String ?? "",
                name: description[kAudioAggregateDeviceNameKey] as? String ?? "",
                transportType: kAudioDeviceTransportTypeAggregate,
                outputStreams: subs.flatMap(\.outputLayout),
                inputStreams: subs.flatMap(\.inputStreams) + Array(repeating: tapStreams, count: tapCount).flatMap { $0 })
            let id = insert(aggregate)
            aggregates[id] = description
            aggregateStreamReads = 0
            return id
        }
    }

    func destroyAggregateDevice(_ device: AudioObjectID) throws(HALError) {
        try locked { () throws(HALError) in
            guard aggregates.removeValue(forKey: device) != nil else {
                throw HALError(kAudioHardwareBadObjectError, "AudioHardwareDestroyAggregateDevice")
            }
            devices[device] = nil
            order.removeAll { $0 == device }
            // Destroying a device also removes its IOProcs.
            for handle in ioProcs.keys where handle.device == device { ioProcs[handle] = nil }
            running = running.filter { $0.device != device }
            _ops.append(.destroyAggregate)
        }
    }

    // MARK: - AudioHAL: IOProcs

    func createIOProc(
        on device: AudioObjectID,
        proc: AudioDeviceIOProc,
        clientData: UnsafeMutableRawPointer?
    ) throws(HALError) -> IOProcHandle {
        try locked { () throws(HALError) -> IOProcHandle in
            try fail(.createIOProc, "AudioDeviceCreateIOProcID")
            _ops.append(.createIOProc)
            let handle = IOProcHandle(device: device, bits: UInt(nextID))
            nextID += 1
            ioProcs[handle] = IOProc(proc: proc, clientData: clientData)
            return handle
        }
    }

    func setInputStreamUsage(_ enabled: [Bool], for proc: IOProcHandle) throws(HALError) {
        try locked { () throws(HALError) in
            try fail(.setStreamUsage, "AudioObjectSetPropertyData", selector: kAudioDevicePropertyIOProcStreamUsage)
            _ops.append(.setStreamUsage(enabled))
        }
    }

    func destroyIOProc(_ proc: IOProcHandle) throws(HALError) {
        try locked { () throws(HALError) in
            guard ioProcs.removeValue(forKey: proc) != nil else {
                throw HALError(kAudioHardwareBadObjectError, "AudioDeviceDestroyIOProcID")
            }
            running.remove(proc)
            _ops.append(.destroyIOProc)
        }
    }

    func startDevice(_ proc: IOProcHandle) throws(HALError) {
        try locked { () throws(HALError) in
            try fail(.start, "AudioDeviceStart")
            _ops.append(.start)
            running.insert(proc)
        }
    }

    func stopDevice(_ proc: IOProcHandle) throws(HALError) {
        lock.withLock {
            _ops.append(.stop)
            running.remove(proc)
        }
    }
}
