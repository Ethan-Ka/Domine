import CoreAudio
import Foundation
@testable import Domine

/// In-memory HAL. Devices get a fresh `AudioObjectID` each time they are added,
/// like real devices after a reconnect.
final class FakeHAL: AudioHAL, @unchecked Sendable {
    struct Device {
        var uid: String
        var name: String
        var outputChannels: Int = 2
        var transportType: UInt32 = kAudioDeviceTransportTypeBluetooth
    }

    private let lock = NSLock()
    private var devices: [AudioObjectID: Device] = [:]
    private var order: [AudioObjectID] = []
    private var nextID: AudioObjectID = 100
    private var defaultOutput: AudioObjectID = kAudioObjectUnknown
    private var listeners: [UUID: (HALProperty, @MainActor @Sendable () -> Void)] = [:]

    /// Status returned by the next read of any property. Cleared after use.
    var failNextRead: OSStatus?

    // MARK: - Test controls

    @MainActor @discardableResult
    func add(_ device: Device) -> AudioObjectID {
        let id = lock.withLock {
            let id = nextID
            nextID += 1
            devices[id] = device
            order.append(id)
            return id
        }
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

    func id(forUID uid: String) -> AudioObjectID? {
        lock.withLock { devices.first { $0.value.uid == uid }?.key }
    }

    var listenerCount: Int { lock.withLock { listeners.count } }

    @MainActor
    private func fire(_ property: HALProperty) {
        let handlers = lock.withLock { listeners.values.filter { $0.0 == property }.map(\.1) }
        handlers.forEach { $0() }
    }

    // MARK: - AudioHAL

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

    func deviceIDs() throws(HALError) -> [AudioObjectID] { lock.withLock { order } }
    func uid(of device: AudioObjectID) throws(HALError) -> String {
        try self.device(device, kAudioDevicePropertyDeviceUID).uid
    }
    func name(of device: AudioObjectID) throws(HALError) -> String {
        try self.device(device, kAudioObjectPropertyName).name
    }
    func outputChannelCount(of device: AudioObjectID) throws(HALError) -> Int {
        try self.device(device, kAudioDevicePropertyStreamConfiguration).outputChannels
    }
    func transportType(of device: AudioObjectID) throws(HALError) -> UInt32 {
        try self.device(device, kAudioDevicePropertyTransportType).transportType
    }
    func defaultOutputDevice() throws(HALError) -> AudioObjectID { lock.withLock { defaultOutput } }
    func setDefaultOutputDevice(_ device: AudioObjectID) throws(HALError) {
        lock.withLock { defaultOutput = device }
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
}
