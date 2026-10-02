import CoreAudio
import os

/// Follows the Domine virtual output's volume and mute and writes Domine's
/// own changes back to it (SPEC sections 3.3 and 4a).
///
/// Writes notify listeners, Domine's own included. The link remembers the
/// last value it wrote or saw and ignores a notification that reads back the
/// same value, and skips writes of a value the device already shows. That
/// keeps the virtual device and the speakers from bouncing one change back
/// and forth. A time window would also swallow real key presses that follow
/// a write, so none is used.
@MainActor
final class VirtualOutputLink {
    static let tolerance: Float = 0.005
    private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "VirtualOutput")
    private static let main = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)

    let device: AudioObjectID
    private let hal: any AudioHAL
    private var tokens: [HALListenerToken] = []
    private(set) var volume: Float?
    private(set) var muted: Bool?
    private var hasVolume = false
    private var hasMute = false

    /// A volume or mute change made by the system, not by Domine.
    var onVolume: (@MainActor (Float) -> Void)?
    var onMute: (@MainActor (Bool) -> Void)?
    /// The default output moved.
    var onDefaultOutputChange: (@MainActor () -> Void)?

    init(hal: any AudioHAL, device: AudioObjectID) {
        self.hal = hal
        self.device = device
        do {
            hasVolume = try hal.volumeElements(of: device).contains(Self.main)
            if hasVolume { volume = try hal.volume(of: device, element: Self.main) }
            muted = try hal.isMuted(of: device)
            hasMute = muted != nil
        } catch {
            Self.log.error("Could not read the virtual output: \(error.description, privacy: .public)")
        }
        listen(.volume(device, element: Self.main), when: hasVolume) { $0.volumeChanged() }
        listen(.mute(device), when: hasMute) { $0.muteChanged() }
        listen(.defaultOutputDevice, when: true) { $0.onDefaultOutputChange?() }
    }

    func cancel() {
        tokens.forEach { $0.cancel() }
        tokens = []
    }

    /// Writes Domine's volume to the device unless it already shows it.
    func mirror(volume value: Float) {
        guard hasVolume else { return }
        if let volume, abs(volume - value) <= Self.tolerance { return }
        volume = value
        do {
            try hal.setVolume(value, of: device, element: Self.main)
        } catch {
            Self.log.error("Could not set the virtual output volume: \(error.description, privacy: .public)")
        }
    }

    func mirror(muted value: Bool) {
        guard hasMute, muted != value else { return }
        muted = value
        do { try hal.setMuted(value, of: device) } catch {
            Self.log.error("Could not set the virtual output mute: \(error.description, privacy: .public)")
        }
    }

    private func listen(_ property: HALProperty, when enabled: Bool,
                        _ handler: @escaping @MainActor (VirtualOutputLink) -> Void) {
        guard enabled else { return }
        do {
            tokens.append(try hal.addListener(property) { [weak self] in
                if let self { handler(self) }
            })
        } catch {
            Self.log.error("Could not listen to the virtual output: \(error.description, privacy: .public)")
        }
    }

    private func volumeChanged() {
        do {
            let value = try hal.volume(of: device, element: Self.main)
            if let volume, abs(volume - value) <= Self.tolerance { return }
            volume = value
            onVolume?(value)
        } catch {
            Self.log.error("Could not read the virtual output volume: \(error.description, privacy: .public)")
        }
    }

    private func muteChanged() {
        do {
            guard let value = try hal.isMuted(of: device), value != muted else { return }
            muted = value
            onMute?(value)
        } catch {
            Self.log.error("Could not read the virtual output mute: \(error.description, privacy: .public)")
        }
    }
}

/// While routing with the virtual output as the default output, the system
/// volume keys and HUD change its volume and mute; Domine applies them to the
/// speakers (SPEC 3.3, 4a). The key event tap is not needed then (SPEC 4b).
extension AppModel {
    /// Attaches or detaches the link to match the engine and the default output.
    func syncVirtualOutput() {
        defer { updateVolumeKeyTap() }
        guard engine.state.isActive, let device = virtualOutputDevice(),
              (try? hal.defaultOutputDevice()) == device else {
            virtualOutput?.cancel()
            virtualOutput = nil
            return
        }
        if virtualOutput?.device == device { return }
        virtualOutput?.cancel()
        let link = VirtualOutputLink(hal: hal, device: device)
        link.onVolume = { [weak self] volume in self?.setMasterVolume(Double(volume)) }
        link.onMute = { [weak self] muted in self?.setMuted(muted) }
        link.onDefaultOutputChange = { [weak self] in self?.syncVirtualOutput() }
        virtualOutput = link
        link.mirror(volume: pairSettings.masterVolume)
        link.mirror(muted: isMuted)
    }

    private func virtualOutputDevice() -> AudioObjectID? {
        guard let id = try? hal.deviceID(forUID: OutputRestorer.virtualOutputUID),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    func mirrorMasterToVirtualOutput() {
        virtualOutput?.mirror(volume: pairSettings.masterVolume)
    }

    func mirrorMuteToVirtualOutput() {
        virtualOutput?.mirror(muted: isMuted)
    }
}
