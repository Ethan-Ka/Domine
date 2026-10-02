import AppKit
import os

/// Accessibility trust, read fresh whenever the UI shows it.
///
/// TCC ties the grant to the app's code signature. A rebuilt or differently
/// signed Domine shows up in System Settings under the same name, so the
/// switch the user sees can belong to another copy. When trust is still
/// missing after a trip to System Settings, the Setup row offers to reveal
/// this exact app so it can be dragged into the list.
extension AppModel {
    /// Grant Access, in Setup and next to the volume keys checkbox. The
    /// prompting call adds this binary to the list; the list opens either
    /// way, since the prompt is skipped when any Domine entry exists.
    func grantAccessibility() {
        services.promptForAccessibility()
        services.openURL(VolumeKeyTap.accessibilitySettingsURL)
        awaitingAccessibilityGrant = true
        refreshAccessibilityTrust()
    }

    /// Shows the running app in Finder, to drag into the Accessibility list.
    func revealAppInFinder() {
        services.revealInFinder(Bundle.main.bundleURL)
    }

    /// Domine came to the front, often back from System Settings.
    func didBecomeActive() {
        if awaitingAccessibilityGrant, !services.isAccessibilityTrusted(), !accessibilityLikelyStale {
            accessibilityLikelyStale = true
            Self.log.notice("Still not trusted after System Settings; this app is \(Bundle.main.bundleURL.path, privacy: .public)")
        }
        refreshSystemStatus()
        updateVolumeKeyTap()
    }

    func settingsDidAppear() {
        isSettingsVisible = true
        refreshSystemStatus()
    }

    func settingsDidDisappear() {
        isSettingsVisible = false
        updateTrustPolling()
    }

    /// Reads AXIsProcessTrusted into the view state. Writes nothing to the
    /// store. Clears the stale-entry hint once trust arrives.
    @discardableResult
    func refreshAccessibilityTrust() -> Bool {
        let trusted = services.isAccessibilityTrusted()
        if generalSettings.accessibilityGranted != trusted {
            Self.log.info("Accessibility trusted: \(trusted)")
            let wasRefreshing = isRefreshingSystemStatus
            isRefreshingSystemStatus = true
            generalSettings.accessibilityGranted = trusted
            isRefreshingSystemStatus = wasRefreshing
        }
        if trusted {
            awaitingAccessibilityGrant = false
            if accessibilityLikelyStale { accessibilityLikelyStale = false }
        }
        updateTrustPolling()
        return trusted
    }

    /// Checks trust every `trustPollInterval` while a "not granted" note is
    /// on screen: the volume keys note (keys on) or the Setup row (Settings
    /// open). A grant made in System Settings then shows without switching
    /// back to Domine. No timer runs otherwise.
    func updateTrustPolling() {
        let noteVisible = store.volumeKeysEnabled || isSettingsVisible
        if noteVisible && !services.isAccessibilityTrusted() {
            guard trustPollTask == nil else { return }
            trustPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let interval = self?.trustPollInterval else { return }
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    let stillVisible = self.store.volumeKeysEnabled || self.isSettingsVisible
                    if !stillVisible || self.services.isAccessibilityTrusted() {
                        self.trustPollTask = nil
                        self.refreshSystemStatus()
                        self.updateVolumeKeyTap()
                        return
                    }
                }
            }
        } else {
            trustPollTask?.cancel()
            trustPollTask = nil
        }
    }

    /// One line at launch, so a log shows which binary TCC is judging.
    func logPermissionsAtLaunch() {
        let path = Bundle.main.bundleURL.path
        let trusted = services.isAccessibilityTrusted()
        let team = CodeSignature.teamIdentifier ?? "none (ad-hoc)"
        let requirement = services.codeSignature() ?? "unreadable"
        Self.log.notice("Running \(path, privacy: .public); Accessibility trusted \(trusted); team \(team, privacy: .public); requirement \(requirement, privacy: .public)")
    }
}
