import AppKit

/// Hardware volume keys drive Domine's master volume (SPEC section 4b).
extension AppModel {
    /// The tap runs only while the user enabled volume keys, Domine has
    /// Accessibility permission, and the engine is playing. Otherwise no tap
    /// exists and the keys keep their normal behavior.
    var wantsVolumeKeyTap: Bool {
        store.volumeKeysEnabled && services.isAccessibilityTrusted() && engine.state == .running
    }

    /// Starts or stops the tap to match `wantsVolumeKeyTap`. Called when the
    /// setting changes, when the engine state changes, and when Domine
    /// becomes active (the user may have just granted Accessibility).
    func updateVolumeKeyTap() {
        if wantsVolumeKeyTap {
            guard !volumeKeyTap.isRunning else { return }
            let started = volumeKeyTap.start { [weak self] event in
                self?.handleVolumeKey(event)
            }
            if !started { Self.log.error("Could not start the volume key tap") }
        } else if volumeKeyTap.isRunning {
            volumeKeyTap.stop()
        }
    }

    /// Applies one key press to the master volume and mute, saves the volume
    /// for the pair, and shows the HUD.
    func handleVolumeKey(_ event: VolumeKeyEvent) {
        let (volume, muted) = event.apply(to: pairSettings.masterVolume, muted: isMuted)
        setMasterVolume(Double(volume))
        setMuted(muted)
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
            MainActor.assumeIsolated { self?.updateVolumeKeyTap() }
        }
    }
}
