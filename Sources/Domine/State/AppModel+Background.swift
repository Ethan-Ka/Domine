import AppKit

/// Background mode (SPEC 6a, docs/mockups/MenuBar.dc.html): with the main
/// window closed and routing on, Domine drops its Dock icon and shows a menu
/// bar item instead. The item is always present.
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
        case .stopAndUseMacSpeakers:
            guard engine.state.isActive else { return }
            userTurnedRoutingOff = true
            stopRouting(toBuiltInOutput: true)
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
    /// Order matters: the Dock policy switches first, and the window work waits
    /// a runloop turn. Opening a window in the same turn as the switch made it
    /// appear behind other apps or flicker while the menu panel was still up.
    /// An existing window is reused, so there is never a second one.
    func showMainWindow() {
        services.closeMenuPanel()
        leaveBackground()
        services.deferToNextTurn { [weak self] in
            guard let self else { return }
            if !self.services.focusMainWindow() { self.presentMainWindow() }
            self.services.activateApp()
        }
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
        var matched: PairSettings.Preset?
        for candidate in PairSettings.Preset.allCases where candidate.settings == pairSettings.effects {
            matched = candidate
            break
        }
        return StatusMenuState(
            statusText: statusLine,
            isOn: engine.state.isActive,
            left: statusMenuSpeaker(.frontLeft),
            right: statusMenuSpeaker(.frontRight),
            masterVolume: Double(pairSettings.masterVolume),
            isMuted: isMuted,
            preset: matched,
            isRouting: engine.state.isRouting,
            rooms: rooms,
            currentRoomID: currentRoomID)
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
        if edited.isMuted != current.isMuted {
            setMuted(edited.isMuted)
        }
        if let preset = edited.preset, preset != current.preset {
            applyPreset(preset)
        }
    }

    var statusMenuActions: StatusMenuActions {
        StatusMenuActions(
            openMainWindow: { [weak self] in self?.showMainWindow() },
            identifySpeaker: { [weak self] position in
                guard let self, let uid = self.uid(at: position) else { return }
                self.playAssignTone(uid: uid)
            },
            swapSides: { [weak self] in self?.swapSides() },
            autoCalibrate: { [weak self] in self?.autoCalibrate() },
            selectRoom: { [weak self] in self?.selectRoom($0) },
            saveRoom: { [weak self] in
                self?.showsSaveRoom = true
                self?.showMainWindow()
            },
            manageRooms: { [weak self] in
                self?.showsManageRooms = true
                self?.showMainWindow()
            },
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
