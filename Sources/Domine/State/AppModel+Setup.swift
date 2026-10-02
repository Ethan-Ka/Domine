/// Replaying the first-run checklist and its prompts from Settings > General.
extension AppModel {
    /// Output devices named "JBL Grip" in the catalog right now.
    var connectedGripCount: Int {
        catalog.outputs.filter { $0.name == DeviceCatalog.gripName }.count
    }

    /// Reads Accessibility trust fresh on every render. When it disagrees
    /// with the cached value, the rest of the UI catches up on the next turn.
    var setupState: SetupState {
        let trusted = services.isAccessibilityTrusted()
        if trusted != generalSettings.accessibilityGranted {
            Task { [weak self] in self?.refreshSystemStatus() }
        }
        return SetupState(
            captureStatus: captureAccess.status,
            isCheckingCapture: captureAccess.isProbing,
            accessibilityGranted: trusted,
            accessibilityLikelyStale: accessibilityLikelyStale && !trusted,
            connectedGrips: connectedGripCount,
            loginItemNeedsApproval: loginItemNeedsApproval)
    }

    /// `showMainWindow` brings the main window forward; it needs the SwiftUI
    /// environment, so the view supplies it.
    func setupActions(showMainWindow: @escaping @MainActor () -> Void = {}) -> SetupActions {
        SetupActions(
            showSetupAgain: { [weak self] in
                self?.showSetupAgain()
                showMainWindow()
            },
            requestCapture: { [weak self] in
                guard let self else { return }
                Task { await self.requestCaptureAccess() }
            },
            openPrivacySettings: { [weak self] in self?.openPrivacySettings() },
            grantAccessibility: { [weak self] in self?.grantAccessibility() },
            revealApp: { [weak self] in self?.revealAppInFinder() },
            openBluetoothSettings: { [weak self] in self?.services.openURL(SystemServices.bluetoothSettingsURL) },
            openLoginItems: { [weak self] in self?.services.openLoginItemsSettings() })
    }

    /// Clears the first-run flag and presents the checklist again.
    func showSetupAgain() {
        store.hasCompletedWelcome = false
        markedJBLUnpaired = false
        showsWelcome = true
    }

    func requestCaptureAccess() async {
        await captureAccess.request()
    }

    func openPrivacySettings() {
        services.openURL(SystemServices.audioCaptureSettingsURL)
    }

    /// The meter reader, polled whenever the engine runs, window or not.
    /// Program audio reaching the kernel proves capture works; a test tone
    /// or click test does not, since the kernel makes those.
    func readMeterPeaks() -> (Float, Float) {
        let peaks = engine.peaks()
        if engine.testTone == .off, !engine.clickTest, peaks.0 > 0 || peaks.1 > 0 {
            captureAccess.markWorking()
        }
        return peaks
    }
}
