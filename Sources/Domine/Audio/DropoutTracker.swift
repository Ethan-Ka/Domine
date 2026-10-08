import CoreAudio
import Foundation

/// Counts processor overloads on each sub-device of the aggregate and
/// disconnects of the assigned speakers (device left the catalog or died).
@MainActor
final class DropoutTracker {
    private let hal: any AudioHAL
    private let devices: [EngineDiagnostics.Device]
    private var tokens: [HALListenerToken] = []
    private var gone: Set<String> = []
    private(set) var counts: DropoutCounts

    init(hal: any AudioHAL, devices: [EngineDiagnostics.Device], now: Date = Date()) {
        self.hal = hal
        self.devices = devices
        counts = DropoutCounts(sessionStart: now)
    }

    func start() {
        for device in devices {
            let uid = device.uid
            add(.processorOverload(device.id)) { [weak self] in self?.counts.recordOverload(uid: uid) }
            add(.isAlive(device.id)) { [weak self] in self?.checkPresence() }
        }
        add(.devices) { [weak self] in self?.checkPresence() }
    }

    func stop() {
        tokens.forEach { $0.cancel() }
        tokens = []
    }

    func reset(at date: Date = Date()) {
        counts.reset(at: date)
    }

    private func add(_ property: HALProperty, _ handler: @escaping @MainActor @Sendable () -> Void) {
        do {
            tokens.append(try hal.addListener(property, handler: handler))
        } catch {
            EngineDiagnostics.log.error("Could not listen for \(String(describing: property), privacy: .public): \(error.description, privacy: .public)")
        }
    }

    private func checkPresence() {
        for device in devices {
            let id = (try? hal.deviceID(forUID: device.uid)) ?? kAudioObjectUnknown
            let present = id != kAudioObjectUnknown && ((try? hal.isAlive(id)) ?? false)
            if present {
                gone.remove(device.uid)
            } else if gone.insert(device.uid).inserted {
                counts.recordDisconnect(uid: device.uid)
            }
        }
    }
}
