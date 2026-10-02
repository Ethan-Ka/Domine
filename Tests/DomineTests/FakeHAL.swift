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
        var inputLatency = DeviceLatency()
        /// nil reads as `sampleRate`.
        var actualSampleRate: Double? = nil
        var availableSampleRates: [ClosedRange<Double>] = [44_100...44_100, 48_000...48_000]
        var bufferFrameSize: UInt32 = 512
        /// The device's real clock for `currentTime`; nil means not running.
        var clockRate: Double? = nil
        /// Settable output volume per element. The default matches a JBL
        /// Grip: no main element, channels 1 and 2 only. Empty means the
        /// device has no settable volume.
        var volumes: [AudioObjectPropertyElement: Float] = [1: 0.5, 2: 0.5]
        /// When set, a written volume snaps to the nearest multiple of this
        /// step, like a Bluetooth speaker's AVRCP volume.
        var volumeStep: Float? = nil
        /// Output mute state; nil means the device has no mute control.
        var mute: Bool? = nil
        /// `kAudioDevicePropertyDeviceIsAlive`. Change it with `setAlive`.
        var isAlive = true

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
    private var _ioProcDevices: [AudioObjectID] = []
    /// Every device an IOProc was created on, in order.
    var ioProcDevices: [AudioObjectID] { lock.withLock { _ioProcDevices } }
    private var aggregateStreamReads = 0
    private var _volumeWrites: [VolumeWrite] = []
    private var _defaultOutputWrites: [String] = []
    private var _muteWrites: [Bool] = []

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
    /// The tap's rate when there is no default output (otherwise it follows
    /// the default output's nominal rate, like the real HAL).
    var tapSampleRate: Double = 48_000
    /// Makes the tap's (and the aggregate's tap streams') format non-interleaved.
    var tapNonInterleaved = false
    /// After a nominal rate write, this many reads of that device's rate
    /// still return the old rate, like the real HAL applying it a moment
    /// later. Until then taps also follow the old rate.
    var rateSettleReads = 0
    /// This many taps created next keep the default output's rate from
    /// before its last rate write, for their whole life, as if created
    /// before the change reached them.
    var staleTaps = 0
    private var pendingRates: [AudioObjectID: (rate: Double, readsLeft: Int)] = [:]
    private var previousRates: [AudioObjectID: Double] = [:]
    private var staleTapRates: [AudioObjectID: Double] = [:]
    private var _currentTimeQueries: [AudioObjectID] = []
    /// Every device `currentTime` was asked about, in order.
    var currentTimeQueries: [AudioObjectID] { lock.withLock { _currentTimeQueries } }

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

    /// Marks a device dead (or alive again) without removing it from the
    /// device list, and notifies `.isAlive` listeners, like a Bluetooth
    /// speaker that stops responding before the HAL drops it.
    @MainActor
    func setAlive(uid: String, _ alive: Bool) {
        let id: AudioObjectID? = lock.withLock {
            guard let id = devices.first(where: { $0.value.uid == uid })?.key else { return nil }
            devices[id]?.isAlive = alive
            return id
        }
        if let id { fire(.isAlive(id)) }
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

    /// Every mute write Domine made, in order.
    var muteWrites: [Bool] { lock.withLock { _muteWrites } }

    /// Changes a device's mute from outside Domine, like the mute key.
    @MainActor
    func pressMute(uid: String, to muted: Bool) {
        let id: AudioObjectID? = lock.withLock {
            guard let id = devices.first(where: { $0.value.uid == uid })?.key else { return nil }
            devices[id]?.mute = muted
            return id
        }
        if let id { fire(.mute(id)) }
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
    func render(input: FakeBufferList, output: FakeBufferList,
                now: AudioTimeStamp = AudioTimeStamp(),
                inputTime: AudioTimeStamp = AudioTimeStamp(),
                outputTime: AudioTimeStamp = AudioTimeStamp()) {
        guard let (handle, proc) = lock.withLock({ () -> (IOProcHandle, IOProc)? in
            guard let handle = running.first, let proc = ioProcs[handle] else { return nil }
            return (handle, proc)
        }) else { return }
        var now = now, inTime = inputTime, outTime = outputTime
        _ = proc.proc(handle.device, &now, input.pointer, &inTime, output.pointer, &outTime, proc.clientData)
    }

    @MainActor
    func fire(_ property: HALProperty) {
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
    func isAlive(_ device: AudioObjectID) throws(HALError) -> Bool {
        try self.device(device, kAudioDevicePropertyDeviceIsAlive).isAlive
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
        _ = try self.device(device, kAudioDevicePropertyNominalSampleRate)
        return lock.withLock {
            if let pending = pendingRates[device] {
                if pending.readsLeft > 0 {
                    pendingRates[device] = (pending.rate, pending.readsLeft - 1)
                } else {
                    pendingRates[device] = nil
                    devices[device]?.sampleRate = pending.rate
                }
            }
            return devices[device]?.sampleRate ?? 0
        }
    }

    func outputLatency(of device: AudioObjectID) throws(HALError) -> DeviceLatency {
        try self.device(device, kAudioDevicePropertyLatency).latency
    }

    func latency(of device: AudioObjectID, scope: StreamScope) throws(HALError) -> DeviceLatency {
        let d = try self.device(device, kAudioDevicePropertyLatency)
        return scope == .output ? d.latency : d.inputLatency
    }

    func actualSampleRate(of device: AudioObjectID) throws(HALError) -> Double {
        let d = try self.device(device, kAudioDevicePropertyActualSampleRate)
        return d.actualSampleRate ?? d.sampleRate
    }

    func availableNominalSampleRates(of device: AudioObjectID) throws(HALError) -> [ClosedRange<Double>] {
        try self.device(device, kAudioDevicePropertyAvailableNominalSampleRates).availableSampleRates
    }

    /// Host ticks the fake's device clocks read in `currentTime`.
    var hostTime: UInt64 = 0

    /// Sample time = host ticks * `clockRate` / `ticksPerSecond`. Fails as
    /// not running when the device has no `clockRate`.
    func currentTime(of device: AudioObjectID) throws(HALError) -> AudioTimeStamp {
        let d = try self.device(device, 0)
        lock.withLock { _currentTimeQueries.append(device) }
        guard let rate = d.clockRate else {
            throw HALError(kAudioHardwareNotRunningError, "AudioDeviceGetCurrentTime")
        }
        let host = lock.withLock { hostTime }
        var t = AudioTimeStamp()
        t.mHostTime = host
        t.mSampleTime = Double(host) * rate / Self.ticksPerSecond
        t.mFlags = [.sampleTimeValid, .hostTimeValid]
        return t
    }

    static var ticksPerSecond: Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return 1e9 * Double(timebase.denom) / Double(timebase.numer)
    }

    func bufferFrameSize(of device: AudioObjectID) throws(HALError) -> UInt32 {
        try self.device(device, kAudioDevicePropertyBufferFrameSize).bufferFrameSize
    }

    func streamFormats(of device: AudioObjectID, scope: StreamScope) throws(HALError) -> [AudioStreamBasicDescription] {
        let channels = try streamChannels(of: device, scope: scope)
        let d = try self.device(device, kAudioStreamPropertyVirtualFormat)
        let tapStreams = scope == .input && lock.withLock { aggregates[device] != nil }
        let rate = tapStreams ? lock.withLock { aggregateTapRate(device) } : d.sampleRate
        return channels.map { Self.format(rate: rate, channels: $0, nonInterleaved: tapStreams && tapNonInterleaved) }
    }

    /// The rate of a tap: stale if it was created stale, else the default
    /// output's. Call with the lock held.
    private func tapRate(_ tap: AudioObjectID) -> Double {
        staleTapRates[tap] ?? devices[defaultOutput]?.sampleRate ?? tapSampleRate
    }

    /// The rate of the first tap in an aggregate. Call with the lock held.
    private func aggregateTapRate(_ aggregate: AudioObjectID) -> Double {
        let uid = (aggregates[aggregate]?[kAudioAggregateDeviceTapListKey] as? [[String: Any]])?
            .first?[kAudioSubTapUIDKey] as? String
        guard let tap = taps.first(where: { $0.value == uid })?.key else {
            return devices[defaultOutput]?.sampleRate ?? tapSampleRate
        }
        return tapRate(tap)
    }

    static func format(rate: Double, channels: Int, nonInterleaved: Bool) -> AudioStreamBasicDescription {
        let bytes = UInt32(nonInterleaved ? 4 : 4 * channels)
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if nonInterleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        return AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    func setNominalSampleRate(_ rate: Double, of device: AudioObjectID) throws(HALError) {
        let d = try self.device(device, kAudioDevicePropertyNominalSampleRate)
        try locked { () throws(HALError) in
            _ops.append(.setSampleRate(uid: d.uid))
            try fail(.setSampleRate, "AudioObjectSetPropertyData", selector: kAudioDevicePropertyNominalSampleRate)
            previousRates[device] = d.sampleRate
            if rateSettleReads > 0 {
                pendingRates[device] = (rate, rateSettleReads)
            } else {
                devices[device]?.sampleRate = rate
            }
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
            var stored = volume
            if let step = d.volumeStep { stored = min(1, (volume / step).rounded() * step) }
            devices[device]?.volumes[element] = stored
            _volumeWrites.append(VolumeWrite(uid: d.uid, element: element, volume: volume))
        }
        MainActor.assumeIsolated { fire(.volume(device, element: element)) }
    }

    func isMuted(of device: AudioObjectID) throws(HALError) -> Bool? {
        try self.device(device, kAudioDevicePropertyMute).mute
    }

    func setMuted(_ muted: Bool, of device: AudioObjectID) throws(HALError) {
        try locked { () throws(HALError) in
            guard let d = devices[device], d.mute != nil else {
                throw HALError(kAudioHardwareUnknownPropertyError, "AudioObjectSetPropertyData", selector: kAudioDevicePropertyMute)
            }
            devices[device]?.mute = muted
            _muteWrites.append(muted)
        }
        MainActor.assumeIsolated { fire(.mute(device)) }
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

    // MARK: Fake processes (SPEC 3b)

    struct Process {
        var bundleID: String
        var isRunningInput = false
    }
    private var processes: [AudioObjectID: Process] = [:]
    private var processOrder: [AudioObjectID] = []

    /// Adds a process object, as when an app starts using audio, and notifies the process-list listeners.
    @discardableResult
    @MainActor func addProcess(bundleID: String, isRunningInput: Bool = false) -> AudioObjectID {
        let id: AudioObjectID = lock.withLock {
            let id = nextID
            nextID += 1
            processes[id] = Process(bundleID: bundleID, isRunningInput: isRunningInput)
            processOrder.append(id)
            return id
        }
        fire(.processObjects)
        return id
    }

    @MainActor func removeProcess(_ id: AudioObjectID) {
        lock.withLock {
            processes[id] = nil
            processOrder.removeAll { $0 == id }
        }
        fire(.processObjects)
    }

    @MainActor func setRunningInput(_ id: AudioObjectID, _ running: Bool) {
        lock.withLock { processes[id]?.isRunningInput = running }
        fire(.processIsRunningInput(id))
    }

    func processObjects() throws(HALError) -> [AudioObjectID] { lock.withLock { processOrder } }

    func processBundleID(of process: AudioObjectID) throws(HALError) -> String {
        guard let p = lock.withLock({ processes[process] }) else {
            throw HALError(kAudioHardwareBadObjectError, "AudioObjectGetPropertyData", selector: kAudioProcessPropertyBundleID)
        }
        return p.bundleID
    }

    func processIsRunningInput(of process: AudioObjectID) throws(HALError) -> Bool {
        guard let p = lock.withLock({ processes[process] }) else {
            throw HALError(kAudioHardwareBadObjectError, "AudioObjectGetPropertyData", selector: kAudioProcessPropertyIsRunningInput)
        }
        return p.isRunningInput
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
            if staleTaps > 0 {
                staleTaps -= 1
                staleTapRates[id] = previousRates[defaultOutput] ?? tapRate(id)
            }
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
            return Self.format(rate: tapRate(tap), channels: 2, nonInterleaved: tapNonInterleaved)
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
                inputStreams: subs.flatMap(\.inputStreams) + Array(repeating: tapStreams, count: tapCount).flatMap { $0 },
                // Like the real HAL, the aggregate runs at its main sub-device's rate.
                sampleRate: subs.first?.sampleRate ?? 48_000)
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
            _ioProcDevices.append(device)
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
