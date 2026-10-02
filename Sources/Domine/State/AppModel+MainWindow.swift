/// Main window state and actions (docs/mockups/Main.dc.html).
extension AppModel {
    static let routingErrorMessage = "Could not start routing"
    nonisolated static let gripPairingHint = "Only one JBL Grip found. Turn off stereo pairing in the JBL Portable app."

    /// One Grip is visible and the selected pair is not both present, so the
    /// second Grip is probably still stereo-paired to the first (SPEC 9).
    var showsGripPairingHint: Bool {
        catalog.showsGripPairingHint && !bothSelectedSpeakersPresent
    }

    var mainWindowState: MainWindowState {
        var cards: [SpeakerCardState] = []
        for position in SpeakerPosition.positions(in: routingMode) { cards.append(card(for: position)) }
        var anyAssigned = false
        for uid in [leftUID, rightUID] {
            if let uid, catalog.device(uid: uid) != nil { anyAssigned = true }
        }
        return MainWindowState(
            statusLine: statusLine,
            isOn: engine.state.isActive,
            mode: routingMode,
            isQuadAvailable: true,
            canSwap: true,
            speakers: cards,
            masterVolume: Double(pairSettings.masterVolume),
            isMuted: isMuted,
            testToneSide: testToneSide,
            canPlayTestTones: engine.state.isRouting
                || anyAssigned,
            bannerMessage: monoFallbackBanner ?? (showsGripPairingHint ? Self.gripPairingHint : nil),
            rearMode: RearMode(rawValue: quadSettings.rearMode) ?? .mirror,
            rearLevel: Double(quadSettings.rearTrim),
            spatialAmount: Double(quadSettings.spatialAmount),
            spatialRoomMs: Double(quadSettings.spatialRoomMs),
            rooms: rooms,
            currentRoomID: currentRoomID)
    }

    var mainWindowActions: MainWindowActions {
        MainWindowActions(
            setOn: { [weak self] in self?.setRouting($0) },
            setMode: { [weak self] in self?.setRoutingMode($0) },
            swap: { [weak self] in self?.swapSides() },
            setMasterVolume: { [weak self] volume in
                // Moving the slider unmutes, as the system volume slider does.
                self?.setMasterVolume(volume)
                self?.setMuted(false)
            },
            setRearMode: { [weak self] in self?.setRearMode($0) },
            setSpatialAmount: { [weak self] in self?.setSpatial(amount: Float($0)) },
            setSpatialRoom: { [weak self] in self?.setSpatial(roomMs: Float($0)) },
            setRearLevel: { [weak self] in self?.setRearTrim(Float($0)) },
            playTestTone: { [weak self] in self?.playTestTone($0) },
            selectSpeaker: { [weak self] in self?.openAssign($0) },
            openTuning: { [weak self] in self?.openTuning() },
            openSound: { [weak self] in self?.openSound() },
            selectRoom: { [weak self] in self?.selectRoom($0) },
            saveRoom: { [weak self] in self?.showsSaveRoom = true },
            manageRooms: { [weak self] in self?.showsManageRooms = true })
    }

    /// The missing speaker's position while the engine is in mono fallback.
    var monoFallbackMissingPosition: SpeakerPosition? {
        switch engine.state.missingSpeaker {
        case .none: return nil
        case .some(.left): return .frontLeft
        case .some: return .frontRight
        }
    }

    /// Stage banner during mono fallback (docs/mockups/Disconnected.dc.html).
    var monoFallbackBanner: String? {
        guard let missing = monoFallbackMissingPosition else { return nil }
        let playing: SpeakerPosition = missing == .frontLeft ? .frontRight : .frontLeft
        return "\(missing.title) disconnected. \(playing.title) plays both sides until it reconnects."
    }

    /// One short phrase for the window subtitle.
    var statusLine: String {
        switch engine.state {
        case .idle:
            if leftUID == nil || rightUID == nil { return "Choose two speakers" }
            return routingRefusal ?? engine.idleReason?.description ?? "Off"
        case .starting: return "Starting"
        case .running:
            if volumeKeysNeedAccessibility { return "Playing, volume keys need Accessibility" }
            if routingMode == .quad { return isQuadAvailable ? "Quad" : "Quad: choose rear speakers" }
            return engine.swapSides ? "Playing, sides swapped" : "Playing"
        case .degraded(.monoFallback): return "Mono fallback"
        case .degraded(.quadFallback): return "Quad, some speakers missing"
        case .stopping: return "Stopping"
        case .error: return Self.routingErrorMessage
        }
    }

    /// The side whose test tone is sounding. The kernel tone is positional
    /// (`.left` is position A, the Front Left card), so it is mapped back
    /// through the swap.
    private var testToneSide: StereoSide? {
        let onA: Bool
        if !engine.state.isRouting, let playing = tones.playingUID {
            guard playing == leftUID || playing == rightUID else { return nil }
            onA = playing == leftUID
        } else {
            switch engine.testTone {
            case .off: return nil
            case .left: onA = true
            case .right: onA = false
            }
        }
        return onA != engine.swapSides ? .left : .right
    }

    /// A front card. Front Left is always position A (the `leftUID` device);
    /// swapping only changes which channel it plays, shown by the side tag.
    /// In mono fallback the missing speaker reads "Not connected" (even if
    /// it is still listed but no longer alive) and the other one plays L+R.
    func card(for position: SpeakerPosition) -> SpeakerCardState {
        let isA = position == .frontLeft
        let tag = position.isFront ? (isA != engine.swapSides ? "L" : "R") : (position == .rearLeft ? "RL" : "RR")
        guard let uid = uid(at: position) else {
            return SpeakerCardState(
                position: position, sideTag: tag, statusText: "Choose a speaker", connection: .unassigned)
        }
        let missing = monoFallbackMissingPosition
        guard missing != position, let device = catalog.device(uid: uid) else {
            return SpeakerCardState(
                position: position, sideTag: tag,
                deviceName: knownNames[uid], uidSuffix: OutputDevice.suffix(forUID: uid),
                statusText: "Not connected", connection: .disconnected)
        }
        let level = engine.state.isRouting && position.isFront ? (isA ? meters.levelA : meters.levelB) : 0
        let isMonoFallback = missing != nil
        return SpeakerCardState(
            position: position, sideTag: isMonoFallback ? "L+R" : tag,
            deviceName: device.name, uidSuffix: device.uidSuffix,
            statusText: isMonoFallback ? "Mono fallback" : "Connected", connection: .connected,
            level: Double(level), isMonoFallback: isMonoFallback)
    }
}
