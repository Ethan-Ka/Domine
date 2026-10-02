import AppKit
import os

/// Hardware volume keys drive Domine's master volume (SPEC section 4b).
extension AppModel {
    static let volumeKeysLog = Logger(subsystem: "com.ethankawley.Domine", category: "VolumeKeys")

    /// Why the tap should not run right now, or nil when it should. The tap
    /// runs only while the user enabled volume keys, Domine has Accessibility
    /// permission, and routing is on. When Domine is off the keys keep their
    /// normal behavior and control the Mac's own output (SPEC 4b).
    var volumeKeyTapBlock: String? {
        if !store.volumeKeysEnabled { return "volume keys are off in Settings" }
        if !engine.state.isActive { return "routing is off" }
        if !services.isAccessibilityTrusted() {
            return "Accessibility is not granted (AXIsProcessTrusted is false; a rebuilt app needs a fresh grant)"
        }
        return nil
    }

    var wantsVolumeKeyTap: Bool { volumeKeyTapBlock == nil }

    /// Volume keys are on but cannot be caught, so they still reach macOS.
    var volumeKeysNeedAccessibility: Bool {
        generalSettings.showsAccessibilityPrompt
    }

    /// Starts or stops the tap to match `wantsVolumeKeyTap`. Called when the
    /// setting changes, when the engine state changes, when Domine becomes
    /// active, and every few seconds while Accessibility is missing.
    func updateVolumeKeyTap() {
        let block = volumeKeyTapBlock
        if let block {
            if volumeKeyTap.isRunning {
                volumeKeyTap.stop()
                Self.volumeKeysLog.info("Volume key tap stopped: \(block, privacy: .public)")
            } else if block != lastVolumeKeyTapBlock {
                Self.volumeKeysLog.info("Volume key tap not running: \(block, privacy: .public)")
            }
        } else if !volumeKeyTap.isRunning {
            let started = volumeKeyTap.start { [weak self] event in
                self?.handleVolumeKey(event)
            }
            if started {
                Self.volumeKeysLog.info("Volume key tap started")
            } else {
                Self.volumeKeysLog.error("Could not create the volume key event tap; the keys keep their normal behavior")
            }
        }
        lastVolumeKeyTapBlock = block
        updateTrustPolling()
    }

    /// Applies one key press to the master volume and mute, saves the volume
    /// for the pair, and shows the HUD.
    func handleVolumeKey(_ event: VolumeKeyEvent) {
        let (volume, muted) = event.apply(to: pairSettings.masterVolume, muted: isMuted)
        setMasterVolume(Double(volume))
        setMuted(muted)
        Self.volumeKeysLog.info("Key \(String(describing: event.key), privacy: .public): master \(self.pairSettings.masterVolume), muted \(muted)")
        showVolumeHUD(Double(pairSettings.masterVolume), isMuted)
    }

    /// Mute uses the kernel's 50 ms fade. The volume is left as it was.
    func setMuted(_ muted: Bool) {
        if isMuted != muted { isMuted = muted }
        if engine.muted != muted { engine.muted = muted }
    }

    func observeActivationForVolumeKeys() {
        guard activationObserver == nil else { return }
        // AppKit posts this on the main thread.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.didBecomeActive()
            }
        }
    }
}
