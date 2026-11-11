/// The first-run checklist (docs/mockups/Welcome.dc.html).
extension AppModel {
    var welcomeState: WelcomeState {
        var state = WelcomeState()
        state.setDone(.unpairJBL, markedJBLUnpaired || connectedGripCount >= 2)
        let bothPresent = leftUID.map { catalog.device(uid: $0) != nil } == true
            && rightUID.map { catalog.device(uid: $0) != nil } == true
        state.setDone(.connectSpeakers, bothPresent)
        // There is no API to read the capture permission; tap audio is the only proof.
        state.setDone(.allowCapture, captureAccess.status == .working)
        state.isCheckingCapture = captureAccess.isProbing
        state.showsPrivacySettings = captureAccess.status == .notConfirmed
        // A build without a bundled driver has nothing to install.
        if services.driverInstaller.bundledDriverURL == nil {
            state.steps.removeAll { $0.kind == .installDriver }
        }
        state.setDone(.installDriver, skippedDriverInstall || driverStatus == .installed)
        state.isInstallingDriver = driverActivity == .install || driverActivity == .update
        state.driverFailure = driverFailure
        return state
    }

    var welcomeActions: WelcomeActions {
        WelcomeActions(
            perform: { [weak self] in self?.performWelcomeStep($0) },
            openPrivacySettings: { [weak self] in self?.openPrivacySettings() },
            continueSetup: { [weak self] in self?.completeWelcome() },
            installDriver: { [weak self] in
                guard let self else { return }
                Task { await self.installDriverFromWelcome() }
            },
            skipDriver: { [weak self] in self?.skippedDriverInstall = true })
    }

    func performWelcomeStep(_ kind: WelcomeStep.Kind) {
        switch kind {
        case .unpairJBL: markedJBLUnpaired = true
        case .connectSpeakers: services.openURL(SystemServices.bluetoothSettingsURL)
        case .allowCapture: Task { await requestCaptureAccess() }
        case .installDriver: Task { await installDriverFromWelcome() }
        }
    }

    /// Install when missing, Update when the installed driver is older.
    func installDriverFromWelcome() async {
        switch driverStatus {
        case .notInstalled: await performDriverAction(.install)
        case .updateAvailable: await performDriverAction(.update)
        case .installed: break
        }
    }

    func completeWelcome() {
        store.hasCompletedWelcome = true
        showsWelcome = false
    }
}
