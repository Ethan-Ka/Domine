import CoreAudio
import Foundation
import os

/// The real `AudioHAL`. The only file that calls `AudioObjectGetPropertyData` and friends.
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

    func outputChannelCount(of device: AudioObjectID) throws(HALError) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        try HALError.check(
            AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size),
            "AudioObjectGetPropertyDataSize", selector: addr.mSelector)
        guard size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try HALError.check(
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw),
            "AudioObjectGetPropertyData", selector: addr.mSelector)
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func transportType(of device: AudioObjectID) throws(HALError) -> UInt32 {
        try readScalar(device, address(kAudioDevicePropertyTransportType), as: UInt32.self)
    }

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
