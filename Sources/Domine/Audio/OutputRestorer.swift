import CoreAudio
import os

/// Saves and restores the system default output around routing (SPEC 3b, 4c).
///
/// The process tap is clocked by the default output device. If that device
/// is one of the routed speakers, the tap and the aggregate fight over one
/// Bluetooth clock: playback wobbles in pitch, drops out, and only one side
/// plays. So before the tap is created the default output is saved and, if
/// it is one of the pair, moved to another device. While routing, a listener
/// moves it off again if anything sets it back to one of the speakers.
@MainActor
final class OutputRestorer {
    enum Failure: Error, Equatable {
        /// Every present output is one of the routed speakers.
        case noOtherOutput
        case hal(HALError)
    }

    private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "Output")

    private let hal: any AudioHAL
    private let store: SettingsStore
    private let outputs: @MainActor () -> [OutputDevice]
    private var guardListener: HALListenerToken?
    private var guardedPair: Set<String> = []
    private var playThroughUID: String?
    private var exclusionsActive = false

    /// `outputs` returns the present output devices (the catalog's list).
    init(hal: any AudioHAL, store: SettingsStore, outputs: @escaping @MainActor () -> [OutputDevice]) {
        self.hal = hal
        self.store = store
        self.outputs = outputs
    }

    // MARK: Routing

    /// Call before creating the tap. Saves the default output as the previous
    /// output and moves the default off the pair if needed. Throws
    /// `.noOtherOutput` without changing anything when no other output exists.
    func prepareForRouting(pair: Set<String>, playThroughUID: String?,
                           exclusionsActive: Bool = false) throws(Failure) {
        self.exclusionsActive = exclusionsActive
        let current = try currentDefaultUID()
        if let current, !Self.isDomine(current) {
            store.previousOutputUID = current
        }
        if let current, pair.contains(current) || Self.isDomine(current)
            || (exclusionsActive && current == Self.virtualOutputUID) {
            guard let target = target(pair: pair, playThroughUID: playThroughUID) else {
                Self.log.error("Default output \(current, privacy: .public) is a routed speaker and no other output exists")
                throw .noOtherOutput
            }
            store.outputNeedsRestore = true
            try setDefault(target, reason: "default output \(current) is a routed speaker")
        } else {
            store.outputNeedsRestore = true
        }
        startGuarding(pair: pair, playThroughUID: playThroughUID)
    }

    /// SPEC 3b: while an exclusion is active the default output is a real
    /// device so excluded apps are heard; otherwise the virtual output is
    /// preferred. Moves the default when routing, and is remembered for the
    /// guard listener. Does nothing to the default output when not routing.
    func setExclusionsActive(_ active: Bool) {
        exclusionsActive = active
        guard !guardedPair.isEmpty,
              let target = target(pair: guardedPair, playThroughUID: playThroughUID),
              let current = try? currentDefaultUID(), current != target else { return }
        do {
            try setDefault(target, reason: active ? "an exclusion became active" : "no exclusion is active")
        } catch {
            Self.log.error("Could not switch the default output: \(String(describing: error), privacy: .public)")
        }
    }

    /// Restores the previous output when routing stops, if `enabled` and the
    /// device still exists. Otherwise the current default is left alone.
    func restore(enabled: Bool) {
        stopGuarding()
        guard store.outputNeedsRestore else { return }
        store.outputNeedsRestore = false
        guard enabled else { return }
        guard let previous = store.previousOutputUID, isPresent(previous) else {
            Self.log.info("Previous output is gone; leaving the default output alone")
            return
        }
        do {
            if try currentDefaultUID() != previous {
                try setDefault(previous, reason: "routing stopped")
            }
        } catch {
            Self.log.error("Could not restore the previous output: \(String(describing: error), privacy: .public)")
        }
    }

    /// At launch: a saved previous output that was never restored means
    /// Domine did not stop cleanly. Call only while routing is not active.
    func recoverAfterCrash(enabled: Bool) {
        guard store.outputNeedsRestore else { return }
        Self.log.info("Routing did not stop cleanly last time; restoring the previous output")
        restore(enabled: enabled)
    }

    // MARK: Choosing a device

    /// Domine's virtual output device. When it is installed it is where the
    /// Mac's own output goes while routing, so the volume keys and the system
    /// volume HUD work natively. The catalog hides it, so it is found by UID.
    static let virtualOutputUID = "com.ethankawley.Domine.VirtualOutput"

    /// Where the Mac's own output goes while the pair is routed when the
    /// virtual output is not installed: the excluded-apps device, else the
    /// previous output, else the built-in output, else any other output.
    /// Never one of the pair, never a Domine device.
    static func fallbackOutput(
        pair: Set<String>, playThroughUID: String?, previousUID: String?, outputs: [OutputDevice]
    ) -> OutputDevice? {
        let candidates = outputs.filter { !pair.contains($0.uid) && !isDomine($0.uid) }
        if let playThroughUID, let device = candidates.first(where: { $0.uid == playThroughUID }) { return device }
        if let previousUID, let device = candidates.first(where: { $0.uid == previousUID }) { return device }
        if let device = candidates.first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn }) { return device }
        return candidates.first
    }

    // MARK: Private

    private func startGuarding(pair: Set<String>, playThroughUID: String?) {
        guardedPair = pair
        self.playThroughUID = playThroughUID
        guard guardListener == nil else { return }
        do {
            guardListener = try hal.addListener(.defaultOutputDevice) { [weak self] in
                self?.defaultOutputChanged()
            }
        } catch {
            Self.log.error("Could not listen to the default output: \(error.description, privacy: .public)")
        }
    }

    private func stopGuarding() {
        guardListener?.cancel()
        guardListener = nil
        guardedPair = []
    }

    private func defaultOutputChanged() {
        guard !guardedPair.isEmpty,
              let current = try? currentDefaultUID(),
              guardedPair.contains(current) || Self.isDomine(current)
                || (exclusionsActive && current == Self.virtualOutputUID)
        else { return }
        guard let target = target(pair: guardedPair, playThroughUID: playThroughUID) else {
            Self.log.error("Default output moved to routed speaker \(current, privacy: .public) and no other output exists")
            return
        }
        do {
            try setDefault(target, reason: "default output was set to routed speaker \(current)")
        } catch {
            Self.log.error("Could not move the default output: \(String(describing: error), privacy: .public)")
        }
    }

    private func currentDefaultUID() throws(Failure) -> String? {
        do throws(HALError) {
            let id = try hal.defaultOutputDevice()
            return id == kAudioObjectUnknown ? nil : try hal.uid(of: id)
        } catch {
            throw .hal(error)
        }
    }

    /// The virtual output when present and no exclusion is active, else `fallbackOutput`.
    private func target(pair: Set<String>, playThroughUID: String?) -> String? {
        if !exclusionsActive, isPresent(Self.virtualOutputUID) { return Self.virtualOutputUID }
        return Self.fallbackOutput(
            pair: pair, playThroughUID: playThroughUID,
            previousUID: store.previousOutputUID, outputs: outputs())?.uid
    }

    /// Looked up through the HAL, since the catalog hides Domine's devices.
    private func isPresent(_ uid: String) -> Bool {
        do {
            return try hal.deviceID(forUID: uid) != kAudioObjectUnknown
        } catch {
            Self.log.error("Could not look up \(uid, privacy: .public): \(error.description, privacy: .public)")
            return false
        }
    }

    private func setDefault(_ uid: String, reason: String) throws(Failure) {
        do throws(HALError) {
            let id = try hal.deviceID(forUID: uid)
            guard id != kAudioObjectUnknown else {
                throw HALError(kAudioHardwareBadDeviceError, "AudioObjectGetPropertyData",
                               selector: kAudioHardwarePropertyTranslateUIDToDevice)
            }
            try hal.setDefaultOutputDevice(id)
            Self.log.info("Default output set to \(uid, privacy: .public): \(reason, privacy: .public)")
        } catch {
            throw .hal(error)
        }
    }

    /// One of Domine's own private devices (an aggregate). The virtual
    /// output is a normal output for this purpose.
    private static func isDomine(_ uid: String) -> Bool {
        uid.hasPrefix(DeviceCatalog.domineUIDPrefix) && uid != virtualOutputUID
    }
}
