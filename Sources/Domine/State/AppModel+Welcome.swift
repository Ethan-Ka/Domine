/// The first-run checklist (docs/mockups/Welcome.dc.html).
extension AppModel {
    var welcomeState: WelcomeState {
        var state = WelcomeState()
        let grips = catalog.outputs.filter { $0.name == DeviceCatalog.gripName }.count
        state.setDone(.unpairJBL, markedJBLUnpaired || grips >= 2)
        let bothPresent = [leftUID, rightUID].allSatisfy { uid in
            uid.map { catalog.device(uid: $0) != nil } ?? false
        }
        state.setDone(.connectSpeakers, bothPresent)
        // There is no API to read the capture permission; a successful start is the best signal.
        state.setDone(.allowCapture, hasRunEngine)
        return state
    }

    var welcomeActions: WelcomeActions {
        WelcomeActions(
            perform: { [weak self] in self?.performWelcomeStep($0) },
            continueSetup: { [weak self] in self?.completeWelcome() })
    }

    func performWelcomeStep(_ kind: WelcomeStep.Kind) {
        switch kind {
        case .unpairJBL: markedJBLUnpaired = true
        case .connectSpeakers: services.openURL(SystemServices.bluetoothSettingsURL)
        case .allowCapture: services.openURL(SystemServices.audioCaptureSettingsURL)
        }
    }

    func completeWelcome() {
        store.hasCompletedWelcome = true
        showsWelcome = false
    }
}
