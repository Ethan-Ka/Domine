import CoreAudio
import Foundation
import os

/// The real `AudioHAL`. The only file that calls Core Audio functions:
/// property access, taps, aggregates, and IOProcs.
final class CoreAudioHAL: AudioHAL {
    private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "HAL")
    private let system = AudioObjectID(kAudioObjectSystemObject)

    func deviceIDs() throws(HALError) -> [AudioObjectID] {
        try readArray(system, address(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
    }

    func uid(of device: AudioObjectID) throws(HALError) -> String {
        try readString(device, kAudioDevicePropertyDeviceUID)
    }

    func name(of device: AudioObjectID) throws(HALError) -> String {
        try readString(device, kAudioObjectPropertyName)
    }

    func deviceID(forUID uid: String) throws(HALError) -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) {
            AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        try HALError.check(status, "AudioObjectGetPropertyData", selector: addr.mSelector)
        return id
    }

    func outputChannelCount(of device: AudioObjectID) throws(HALError) -> Int {
        try streamChannels(of: device, scope: .output).reduce(0, +)
    }

    func streamChannels(of device: AudioObjectID, scope: StreamScope) throws(HALError) -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope.propertyScope)
        var size: UInt32 = 0
        try HALError.check(
            AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size),
            "AudioObjectGetPropertyDataSize", selector: addr.mSelector)
        guard size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try HALError.check(
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw),
            "AudioObjectGetPropertyData", selector: addr.mSelector)
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    func nominalSampleRate(of device: AudioObjectID) throws(HALError) -> Double {
        try readScalar(device, address(kAudioDevicePropertyNominalSampleRate), as: Float64.self)
    }

    func setNominalSampleRate(_ rate: Double, of device: AudioObjectID) throws(HALError) {
        try writeScalar(device, address(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }

    func outputLatency(of device: AudioObjectID) throws(HALError) -> DeviceLatency {
        try latency(of: device, scope: .output)
    }

    func latency(of device: AudioObjectID, scope: StreamScope) throws(HALError) -> DeviceLatency {
        let s = scope.propertyScope
        let streams = try readArray(device, address(kAudioDevicePropertyStreams, scope: s), of: AudioObjectID.self)
        var streamFrames: UInt32 = 0
        for stream in streams {
            let frames = try readScalar(stream, address(kAudioStreamPropertyLatency), as: UInt32.self)
            streamFrames = max(streamFrames, frames)
        }
        return DeviceLatency(
            deviceFrames: try readScalar(device, address(kAudioDevicePropertyLatency, scope: s), as: UInt32.self),
            safetyOffsetFrames: try readScalar(device, address(kAudioDevicePropertySafetyOffset, scope: s), as: UInt32.self),
            streamFrames: streamFrames)
    }

    func actualSampleRate(of device: AudioObjectID) throws(HALError) -> Double {
        try readScalar(device, address(kAudioDevicePropertyActualSampleRate), as: Float64.self)
    }

    func availableNominalSampleRates(of device: AudioObjectID) throws(HALError) -> [ClosedRange<Double>] {
        try readArray(device, address(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)
            .map { min($0.mMinimum, $0.mMaximum)...max($0.mMinimum, $0.mMaximum) }
    }

    func currentTime(of device: AudioObjectID) throws(HALError) -> AudioTimeStamp {
        var time = AudioTimeStamp()
        time.mFlags = [.sampleTimeValid, .hostTimeValid]
        try HALError.check(AudioDeviceGetCurrentTime(device, &time), "AudioDeviceGetCurrentTime")
        return time
    }

    func bufferFrameSize(of device: AudioObjectID) throws(HALError) -> UInt32 {
        try readScalar(device, address(kAudioDevicePropertyBufferFrameSize), as: UInt32.self)
    }

    func streamFormats(of device: AudioObjectID, scope: StreamScope) throws(HALError) -> [AudioStreamBasicDescription] {
        let streams = try readArray(
            device, address(kAudioDevicePropertyStreams, scope: scope.propertyScope), of: AudioObjectID.self)
        var formats: [AudioStreamBasicDescription] = []
        for stream in streams {
            formats.append(try readScalar(
                stream, address(kAudioStreamPropertyVirtualFormat), as: AudioStreamBasicDescription.self))
        }
        return formats
    }

    func transportType(of device: AudioObjectID) throws(HALError) -> UInt32 {
        try readScalar(device, address(kAudioDevicePropertyTransportType), as: UInt32.self)
    }

    func isAlive(_ device: AudioObjectID) throws(HALError) -> Bool {
        try readScalar(device, address(kAudioDevicePropertyDeviceIsAlive), as: UInt32.self) != 0
    }

    // MARK: - Hardware volume

    func volumeElements(of device: AudioObjectID) throws(HALError) -> [AudioObjectPropertyElement] {
        if try isVolumeSettable(device, element: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        let channels = try outputChannelCount(of: device)
        guard channels > 0 else { return [] }
        var elements: [AudioObjectPropertyElement] = []
        for channel in 1...AudioObjectPropertyElement(channels) where try isVolumeSettable(device, element: channel) {
            elements.append(channel)
        }
        return elements
    }

    func volume(of device: AudioObjectID, element: AudioObjectPropertyElement) throws(HALError) -> Float {
        try readScalar(device, volumeAddress(element), as: Float32.self)
    }

    func setVolume(_ volume: Float, of device: AudioObjectID, element: AudioObjectPropertyElement) throws(HALError) {
        try writeScalar(device, volumeAddress(element), Float32(min(max(volume, 0), 1)))
    }

    private func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element)
    }

    /// True when the element has an output volume and it can be set.
    private func isVolumeSettable(_ device: AudioObjectID, element: AudioObjectPropertyElement) throws(HALError) -> Bool {
        var addr = volumeAddress(element)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        try HALError.check(
            AudioObjectIsPropertySettable(device, &addr, &settable),
            "AudioObjectIsPropertySettable", selector: addr.mSelector)
        return settable.boolValue
    }

    func isMuted(of device: AudioObjectID) throws(HALError) -> Bool? {
        var addr = muteAddress
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var settable: DarwinBoolean = false
        try HALError.check(
            AudioObjectIsPropertySettable(device, &addr, &settable),
            "AudioObjectIsPropertySettable", selector: addr.mSelector)
        guard settable.boolValue else { return nil }
        return try readScalar(device, addr, as: UInt32.self) != 0
    }

    func setMuted(_ muted: Bool, of device: AudioObjectID) throws(HALError) {
        try writeScalar(device, muteAddress, UInt32(muted ? 1 : 0))
    }

    private var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: - Default output

    func defaultOutputDevice() throws(HALError) -> AudioObjectID {
        try readScalar(system, address(kAudioHardwarePropertyDefaultOutputDevice), as: AudioObjectID.self)
    }

    func setDefaultOutputDevice(_ device: AudioObjectID) throws(HALError) {
        try writeScalar(system, address(kAudioHardwarePropertyDefaultOutputDevice), device)
    }

    func addListener(
        _ property: HALProperty,
        handler: @escaping @MainActor @Sendable () -> Void
    ) throws(HALError) -> HALListenerToken {
        let object = property.object
        var addr = property.address
        // Core Audio only calls the block on the main queue, and the removal
        // closure passes it back unchanged, so sharing it is safe.
        nonisolated(unsafe) let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        try HALError.check(
            AudioObjectAddPropertyListenerBlock(object, &addr, .main, block),
            "AudioObjectAddPropertyListenerBlock", selector: addr.mSelector)
        let removeAddr = addr
        return HALListenerToken {
            var a = removeAddr
            let status = AudioObjectRemovePropertyListenerBlock(object, &a, .main, block)
            // A listener on a device that has already vanished cannot be removed; that is fine.
            if status != noErr && status != kAudioHardwareBadObjectError {
                Self.log.error("\(HALError(status, "AudioObjectRemovePropertyListenerBlock", selector: a.mSelector).description)")
            }
        }
    }

    // MARK: - Process taps

    func ownProcessObject() throws(HALError) -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        try HALError.check(status, "AudioObjectGetPropertyData", selector: addr.mSelector)
        return object
    }

    func processObjects() throws(HALError) -> [AudioObjectID] {
        try readArray(system, address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
    }

    func processBundleID(of process: AudioObjectID) throws(HALError) -> String {
        try readString(process, kAudioProcessPropertyBundleID)
    }

    func processIsRunningInput(of process: AudioObjectID) throws(HALError) -> Bool {
        try readScalar(process, address(kAudioProcessPropertyIsRunningInput), as: UInt32.self) != 0
    }

    func createProcessTap(excluding processes: [AudioObjectID], muted: Bool) throws(HALError) -> ProcessTap {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        description.name = "Domine"
        description.muteBehavior = muted ? .muted : .unmuted
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        try HALError.check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        do {
            return ProcessTap(id: tap, uid: try readString(tap, kAudioTapPropertyUID))
        } catch {
            // Do not leak a tap (possibly muting) if its UID cannot be read.
            let status = AudioHardwareDestroyProcessTap(tap)
            if status != noErr {
                Self.log.error("\(HALError(status, "AudioHardwareDestroyProcessTap").description)")
            }
            throw error
        }
    }

    func destroyProcessTap(_ tap: AudioObjectID) throws(HALError) {
        try HALError.check(AudioHardwareDestroyProcessTap(tap), "AudioHardwareDestroyProcessTap")
    }

    func tapFormat(of tap: AudioObjectID) throws(HALError) -> AudioStreamBasicDescription {
        try readScalar(tap, address(kAudioTapPropertyFormat), as: AudioStreamBasicDescription.self)
    }

    // MARK: - Aggregate devices

    func createAggregateDevice(_ description: [String: Any]) throws(HALError) -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        try HALError.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &device),
            "AudioHardwareCreateAggregateDevice")
        return device
    }

    func destroyAggregateDevice(_ device: AudioObjectID) throws(HALError) {
        try HALError.check(AudioHardwareDestroyAggregateDevice(device), "AudioHardwareDestroyAggregateDevice")
    }

    // MARK: - IOProcs

    func createIOProc(
        on device: AudioObjectID,
        proc: AudioDeviceIOProc,
        clientData: UnsafeMutableRawPointer?
    ) throws(HALError) -> IOProcHandle {
        var procID: AudioDeviceIOProcID?
        try HALError.check(
            AudioDeviceCreateIOProcID(device, proc, clientData, &procID), "AudioDeviceCreateIOProcID")
        guard let procID else {
            throw HALError(kAudioHardwareUnspecifiedError, "AudioDeviceCreateIOProcID")
        }
        return IOProcHandle(device: device, bits: unsafeBitCast(procID, to: UInt.self))
    }

    func setInputStreamUsage(_ enabled: [Bool], for proc: IOProcHandle) throws(HALError) {
        var addr = address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let size = max(
            flagsOffset + enabled.count * MemoryLayout<UInt32>.stride,
            MemoryLayout<AudioHardwareIOProcStreamUsage>.size)
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = UnsafeMutableRawPointer(bitPattern: proc.bits)!
        usage.pointee.mNumberStreams = UInt32(enabled.count)
        let flags = (raw + flagsOffset).assumingMemoryBound(to: UInt32.self)
        for (index, on) in enabled.enumerated() { flags[index] = on ? 1 : 0 }
        try HALError.check(
            AudioObjectSetPropertyData(proc.device, &addr, 0, nil, UInt32(size), raw),
            "AudioObjectSetPropertyData", selector: addr.mSelector)
    }

    func destroyIOProc(_ proc: IOProcHandle) throws(HALError) {
        try HALError.check(
            AudioDeviceDestroyIOProcID(proc.device, procID(proc)), "AudioDeviceDestroyIOProcID")
    }

    func startDevice(_ proc: IOProcHandle) throws(HALError) {
        try HALError.check(AudioDeviceStart(proc.device, procID(proc)), "AudioDeviceStart")
    }

    func stopDevice(_ proc: IOProcHandle) throws(HALError) {
        try HALError.check(AudioDeviceStop(proc.device, procID(proc)), "AudioDeviceStop")
    }

    private func procID(_ proc: IOProcHandle) -> AudioDeviceIOProcID {
        unsafeBitCast(proc.bits, to: AudioDeviceIOProcID.self)
    }

    // MARK: - Helpers

    private func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func readScalar<T: BitwiseCopyable>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as: T.Type
    ) throws(HALError) -> T {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        try HALError.check(
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, value),
            "AudioObjectGetPropertyData", selector: addr.mSelector)
        return value.pointee
    }

    private func writeScalar<T: BitwiseCopyable>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T
    ) throws(HALError) {
        var addr = address
        var v = value
        let status = withUnsafePointer(to: &v) {
            AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        try HALError.check(status, "AudioObjectSetPropertyData", selector: addr.mSelector)
    }

    private func readArray<T: BitwiseCopyable>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of: T.Type
    ) throws(HALError) -> [T] {
        var addr = address
        var size: UInt32 = 0
        try HALError.check(
            AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size),
            "AudioObjectGetPropertyDataSize", selector: addr.mSelector)
        let capacity = Int(size) / MemoryLayout<T>.stride
        guard capacity > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        try HALError.check(
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer),
            "AudioObjectGetPropertyData", selector: addr.mSelector)
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    private func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws(HALError) -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        try HALError.check(status, "AudioObjectGetPropertyData", selector: selector)
        return (value?.takeRetainedValue() as String?) ?? ""
    }
}
