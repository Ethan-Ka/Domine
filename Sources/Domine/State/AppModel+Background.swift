import AppKit

/// Background mode (SPEC 6a, docs/mockups/MenuBar.dc.html): with the main
/// window closed and routing on, Domine drops its Dock icon and shows a menu
/// bar item instead. The item exists only in background mode.
extension AppModel {
    /// The main window closed. "Stop playing" stops routing. "Keep playing"
    /// goes to the background, but only while routing: with routing off there
    /// is nothing to keep playing, so Domine stays a normal Dock app and the
    /// Dock icon reopens the window.
    func mainWindowDidClose() {
        switch store.closeBehavior {
        case .stopPlaying:
            guard engine.state.isActive else { return }
            userTurnedRoutingOff = true
            stopRouting()
        case .keepPlaying:
            guard engine.state.isActive else { return }
            enterBackground()
        }
    }

    /// Hides the Dock icon and inserts the menu bar item. Background mode
    /// lasts until the window opens again, even if routing stops meanwhile,
    /// so auto-start can bring the speakers back with no window open.
    func enterBackground() {
        guard !isInBackground else { return }
        isInBackground = true
        services.setActivationPolicy(.accessory)
    }

    /// Restores the Dock icon and removes the menu bar item.
    func leaveBackground() {
        guard isInBackground else { return }
        isInBackground = false
        services.setActivationPolicy(.regular)
    }

    /// Open Domine in the menu, a Dock click, or launching the app again.
    func showMainWindow() {
        leaveBackground()
        presentMainWindow()
        services.activateApp()
    }

    /// Quit Domine in the menu. Routing stops in `appWillTerminate`.
    func quit() {
        services.terminateApp()
    }

    /// Never leave a tap or the pair as default output behind on quit.
    func appWillTerminate() {
        stopRouting()
    }

    // MARK: - Menu content

    var statusMenuState: StatusMenuState {
        StatusMenuState(
            statusText: statusLine,
            isOn: engine.state.isActive,
            left: statusMenuSpeaker(.frontLeft),
            right: statusMenuSpeaker(.frontRight),
            masterVolume: Double(pairSettings.masterVolume))
    }

    /// Applies an edit made through the menu's switch or volume slider.
    func applyStatusMenuEdit(_ edited: StatusMenuState) {
        let current = statusMenuState
        if edited.isOn != current.isOn {
            setRouting(edited.isOn)
        }
        if edited.masterVolume != current.masterVolume {
            mainWindowActions.setMasterVolume(edited.masterVolume)
        }
    }

    var statusMenuActions: StatusMenuActions {
        StatusMenuActions(
            openMainWindow: { [weak self] in self?.showMainWindow() },
            quit: { [weak self] in self?.quit() })
    }

    private func statusMenuSpeaker(_ position: SpeakerPosition) -> StatusMenuSpeaker {
        let card = card(for: position)
        return StatusMenuSpeaker(
            position: position.title,
            deviceName: card.connection == .unassigned ? card.statusText : card.deviceName ?? "",
            uidSuffix: card.uidSuffix ?? "",
            isConnected: card.connection == .connected)
    }
}
