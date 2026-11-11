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
        // A running watchdog outlives Domine and pauses playback (SPEC 16.11).
        pauseWatchdog.appWillTerminate()
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
            mode: routingMode,
            isSurroundAvailable: isSurroundAvailable,
            speakers: statusMenuSpeakers,
            masterVolume: Double(pairSettings.masterVolume),
            maxVolume: Double(maxMasterVolume),
            isMuted: isMuted,
            preset: matched,
            isRouting: engine.state.isRouting,
            apps: statusMenuApps,
            appVolumeLimitReached: appVolumeLimitReached,
            rooms: rooms,
            currentRoomID: currentRoomID)
    }

    /// Applies an edit made through the menu's switch or volume slider.
    func applyStatusMenuEdit(_ edited: StatusMenuState) {
        let current = statusMenuState
        if edited.mode != current.mode {
            setRoutingMode(edited.mode)
        }
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
        for app in edited.apps {
            guard let old = current.apps.first(where: { $0.bundleID == app.bundleID }) else { continue }
            if app.volume != old.volume { setAppVolume(bundleID: app.bundleID, app.volume) }
            if app.isExcluded != old.isExcluded { setAppExcluded(bundleID: app.bundleID, app.isExcluded) }
        }
    }

    var statusMenuActions: StatusMenuActions {
        StatusMenuActions(
            openMainWindow: { [weak self] in self?.showMainWindow() },
            identifySpeaker: { [weak self] uid in
                guard let self else { return }
                if self.routingMode == .surround {
                    self.playTestTone(surroundUID: uid)
                } else {
                    self.playAssignTone(uid: uid)
                }
            },
            swapSides: { [weak self] in self?.swapSides() },
            autoCalibrate: { [weak self] in self?.autoCalibrate() },
            selectRoom: { [weak self] in self?.selectRoom($0) },
            saveRoom: { [weak self] in
                self?.showsSaveRoom = true
                self?.showMainWindow()
            },
            bluetoothSpeakers: { [weak self] in
                self?.openBluetooth()
                self?.showMainWindow()
            },
            manageRooms: { [weak self] in
                self?.showsManageRooms = true
                self?.showMainWindow()
            },
            quit: { [weak self] in self?.quit() })
    }

    /// One row per card of the current mode, in the stage's order.
    var statusMenuSpeakers: [StatusMenuSpeaker] {
        let cards = routingMode == .surround
            ? surroundCards
            : SpeakerPosition.positions(in: routingMode).map { card(for: $0) }
        return cards.map { card in
            let uid = card.surround?.uid ?? uid(at: card.position)
            return StatusMenuSpeaker(
                position: card.title,
                uid: uid,
                deviceName: card.connection == .unassigned ? card.statusText : card.deviceName ?? "",
                uidSuffix: card.uidSuffix ?? "",
                connection: Self.statusMenuConnection(card),
                batteryPercent: card.batteryPercent,
                isPlayingTone: uid.map(isPlayingIdentifyTone(uid:)) ?? false)
        }
    }

    nonisolated static func statusMenuConnection(_ card: SpeakerCardState) -> StatusMenuConnection {
        switch card.connection {
        case .connected: .connected
        case .disconnected: card.isReconnecting ? .connecting : .notConnected
        case .unassigned, .placeholder: .unassigned
        }
    }

    /// The identification or test tone is sounding on this device, either
    /// straight on the device or through the engine.
    func isPlayingIdentifyTone(uid: String) -> Bool {
        if tones.playingUID == uid { return true }
        if routingMode == .surround { return surroundTestToneUID == uid }
        guard engine.state.isRouting else { return false }
        switch engine.testTone {
        case .off: return false
        case .left: return uid == leftUID
        case .right: return uid == rightUID
        }
    }

    // MARK: - Menu bar item

    /// The icon's badge and text, per Settings > General > Menu bar shows.
    var menuBarLabel: MenuBarLabelState {
        var showsWarning = false
        if case .degraded = engine.state { showsWarning = true }
        let text: String?
        switch menuBarShows {
        case .iconOnly: text = nil
        case .iconAndVolume: text = isMuted ? "Muted" : VolumeText.label(Double(pairSettings.masterVolume))
        case .iconAndMode: text = routingMode.title
        }
        return MenuBarLabelState(showsWarning: showsWarning, text: text)
    }
}
