import CoreAudio
import Observation
import os

/// The live list of output devices. Refreshes when devices appear or vanish,
/// when the default output changes, and when a device is renamed.
@MainActor
@Observable
final class DeviceCatalog {
    /// UIDs starting with this belong to Domine's own aggregates and are never listed.
    static let domineUIDPrefix = "com.ethankawley.Domine."
    static let gripName = "JBL Grip"

    private(set) var outputs: [OutputDevice] = []
    private(set) var defaultOutputUID: String?
    private(set) var lastError: HALError?

    @ObservationIgnored private let hal: any AudioHAL
    @ObservationIgnored private var systemListeners: [HALListenerToken] = []
    @ObservationIgnored private var nameListeners: [String: HALListenerToken] = [:]

    init(hal: any AudioHAL) {
        self.hal = hal
    }

    func start() {
        guard systemListeners.isEmpty else { return }
        do {
            systemListeners = [
                try hal.addListener(.devices) { [weak self] in self?.refresh() },
                try hal.addListener(.defaultOutputDevice) { [weak self] in self?.refreshDefault() },
            ]
        } catch {
            lastError = error
        }
        refresh()
    }

    func stop() {
        systemListeners.forEach { $0.cancel() }
        systemListeners = []
        nameListeners.values.forEach { $0.cancel() }
        nameListeners = [:]
    }

    func device(uid: String) -> OutputDevice? {
        outputs.first { $0.uid == uid }
    }

    /// Exactly one Grip is visible, which usually means the pair is still
    /// stereo-linked in the JBL Portable app (SPEC section 9).
    var showsGripPairingHint: Bool {
        outputs.filter { $0.name == Self.gripName }.count == 1
    }

    func refresh() {
        let ids: [AudioObjectID]
        do {
            ids = try hal.deviceIDs()
        } catch {
            lastError = error
            return
        }
        var found: [OutputDevice] = []
        for id in ids {
            do {
                let channels = try hal.outputChannelCount(of: id)
                guard channels > 0 else { continue }
                let uid = try hal.uid(of: id)
                guard !uid.hasPrefix(Self.domineUIDPrefix) else { continue }
                found.append(OutputDevice(
                    uid: uid,
                    id: id,
                    name: try hal.name(of: id),
                    outputChannels: channels,
                    transportType: try hal.transportType(of: id)))
            } catch where error.isBadObject {
                continue  // Vanished while we were reading it; the next notification catches up.
            } catch {
                lastError = error
            }
        }
        if found != outputs { outputs = found }
        updateNameListeners()
        refreshDefault()
    }

    private func refreshDefault() {
        do {
            let id = try hal.defaultOutputDevice()
            let uid = id == kAudioObjectUnknown ? nil : try hal.uid(of: id)
            if uid != defaultOutputUID { defaultOutputUID = uid }
        } catch {
            lastError = error
        }
    }

    private func updateNameListeners() {
        let current = Dictionary(uniqueKeysWithValues: outputs.map { ($0.uid, $0.id) })
        for uid in nameListeners.keys where current[uid] == nil {
            nameListeners.removeValue(forKey: uid)?.cancel()
        }
        for (uid, id) in current where nameListeners[uid] == nil {
            do {
                nameListeners[uid] = try hal.addListener(.name(id)) { [weak self] in self?.refresh() }
            } catch {
                lastError = error
            }
        }
    }
}
