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
        let isSurround = routingMode == .surround
        let cards: [SpeakerCardState] = isSurround
            ? surroundCards
            : SpeakerPosition.positions(in: .stereo).map { card(for: $0) }
        var anyAssigned = false
        for uid in [leftUID, rightUID] {
            if let uid, catalog.device(uid: uid) != nil { anyAssigned = true }
        }
        let settings = surroundSettings
        return MainWindowState(
            statusLine: statusLine,
            isOn: engine.state.isActive,
            mode: routingMode,
            isSurroundAvailable: isSurroundAvailable,
            canSwap: !isSurround,
            speakers: cards,
            masterVolume: Double(pairSettings.masterVolume),
            isMuted: isMuted,
            testToneSide: testToneSide,
            canPlayTestTones: isSurround
                ? !connectedSurroundSpeakers.isEmpty
                : engine.state.isRouting || anyAssigned,
            bannerMessage: monoFallbackBanner ?? (showsGripPairingHint ? Self.gripPairingHint : nil),
            surround: SurroundControls(
                width: Double(settings.width),
                level: Double(settings.surroundLevel),
                // The model counts degrees per second; the slider turns.
                orbitRate: Double(settings.orbitRate) / 360,
                rotation: Double(settings.rotation),
                showsBluetoothWarning: showsBluetoothBandwidthWarning),
            canAddSurroundSpeaker: surroundSpeakers.count < SurroundSpeaker.maxCount,
            demo: DemoState(
                isPlaying: demoPlaying,
                azimuth: Double(demoAzimuth),
                sectionTitle: demoSectionTitle,
                canPlay: canPlayDemo),
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
            playTestTone: { [weak self] in self?.playTestTone($0) },
            testSurroundSpeakers: { [weak self] in self?.testSurroundSpeakers() },
            selectSpeaker: { [weak self] in self?.openAssign($0) },
            openTuning: { [weak self] in self?.openTuning() },
            openSound: { [weak self] in self?.openSound() },
            // Add and Choose present a sheet whose state MainView holds
            // (SurroundAssignPresenter); MainView fills those two in.
            removeSurroundSpeaker: { [weak self] in self?.removeSurroundSpeaker(uid: $0) },
            moveSurroundSpeaker: { [weak self] uid, azimuth, distance in
                self?.moveSurroundSpeaker(uid: uid, azimuth: Float(azimuth), distance: Float(distance))
            },
            resetSurroundOrbit: { [weak self] in self?.resetSurroundOrbit() },
            playSurroundTestTone: { [weak self] in self?.playTestTone(surroundUID: $0) },
            applySurroundPreset: { [weak self] in self?.applySurroundPreset($0) },
            setSurroundWidth: { [weak self] in self?.setSurroundWidth(Float($0)) },
            setSurroundLevel: { [weak self] in self?.setSurroundLevel(Float($0)) },
            setOrbitRate: { [weak self] in self?.setOrbitRate(Float($0 * 360)) },
            setSurroundRotation: { [weak self] in self?.setSurroundRotation(Float($0)) },
            toggleDemo: { [weak self] in self?.toggleDemo() },
            selectRoom: { [weak self] in self?.selectRoom($0) },
            saveRoom: { [weak self] in self?.showsSaveRoom = true },
            manageRooms: { [weak self] in self?.showsManageRooms = true })
    }

    /// "Play Demo" / "Stop Demo" (SPEC section 14).
    func toggleDemo() {
        if demoPlaying { stopDemo() } else { startDemo() }
    }

    /// Sync & Balance with the demo button filled in.
    var tuningSheetState: TuningState {
        var state = tuningState
        state.isDemoPlaying = demoPlaying
        state.demoSectionTitle = demoPlaying ? demoSectionTitle : nil
        state.canPlayDemo = canPlayDemo
        if routingMode == .surround, !surroundSpeakers.isEmpty {
            let settings = surroundSettings
            state.surroundRows = settings.speakers.map { (speaker: SurroundSpeaker) -> SurroundTuningRow in
                SurroundTuningRow(
                    uid: speaker.uid,
                    title: SurroundCardInfo.title(forAzimuth: Double(speaker.azimuth)),
                    suffix: catalog.device(uid: speaker.uid)?.uidSuffix ?? OutputDevice.suffix(forUID: speaker.uid),
                    trim: Double(settings.trim(for: speaker.uid)),
                    offsetMs: Double(settings.offsetMs(for: speaker.uid)))
            }
            state.isSurroundTimingMeasured = settings.timingMeasured
        }
        return state
    }

    var tuningSheetActions: TuningActions {
        var actions = tuningActions
        actions.toggleDemo = { [weak self] in self?.toggleDemo() }
        actions.resetSurround = { [weak self] in self?.resetSurroundTuning() }
        actions.setSurroundTrim = { [weak self] uid, trim in self?.setSurroundTrim(uid: uid, Float(trim)) }
        actions.setSurroundOffset = { [weak self] uid, ms in
            self?.setSurroundOffset(uid: uid, ms: Float(ms.rounded()))
        }
        return actions
    }

    /// The Sound sheet with Surround's per-speaker effects filled in.
    var soundSheetState: SoundState {
        var state = soundState
        if routingMode == .surround, !surroundSpeakers.isEmpty {
            let settings = surroundSettings
            state.surround = SurroundSound(
                speakers: settings.speakers.map { (speaker: SurroundSpeaker) -> SurroundSound.Speaker in
                    SurroundSound.Speaker(
                        uid: speaker.uid,
                        title: SurroundCardInfo.title(forAzimuth: Double(speaker.azimuth)),
                        suffix: catalog.device(uid: speaker.uid)?.uidSuffix ?? OutputDevice.suffix(forUID: speaker.uid),
                        effects: surroundEffects(uid: speaker.uid))
                },
                isLinked: settings.linkEffects)
        }
        return state
    }

    var soundSheetActions: SoundActions {
        var actions = soundActions
        actions.setSurroundEffects = { [weak self] uid, effects in self?.setSurroundEffects(uid: uid, effects) }
        actions.setSurroundLinked = { [weak self] in self?.setSurroundEffectsLinked($0) }
        return actions
    }

    // MARK: - Surround

    /// One card per Surround speaker, in the model's order.
    var surroundCards: [SpeakerCardState] {
        let toneUID = surroundTestToneUID
        let routing = engine.state.isRouting
        return surroundSpeakers.map { (speaker: SurroundSpeaker) -> SpeakerCardState in
            let info = SurroundCardInfo(
                uid: speaker.uid, azimuth: Double(speaker.azimuth), distance: Double(speaker.distance))
            guard let device = catalog.device(uid: speaker.uid) else {
                return SpeakerCardState.surroundCard(
                    info, deviceName: knownNames[speaker.uid],
                    uidSuffix: OutputDevice.suffix(forUID: speaker.uid),
                    statusText: "Not connected", connection: .disconnected)
            }
            return SpeakerCardState.surroundCard(
                info, deviceName: device.name, uidSuffix: device.uidSuffix,
                statusText: toneUID == speaker.uid ? "Playing test tone" : "Connected",
                connection: .connected,
                level: routing ? Double(surroundLevel(uid: speaker.uid)) : 0)
        }
    }

    /// The Choose Speaker sheet in Surround mode.
    func surroundAssignSheetState(for target: SurroundAssignTarget, selection: String?) -> AssignSheetState {
        let speakers = surroundSpeakers
        // Outputs with one channel cannot join a surround set (SPEC 13.2).
        let rows = surroundEligibleOutputs.map { (device: OutputDevice) -> AssignRow in
            var details = [device.transportName]
            if device.uid != target.replacedUID, let placed = speakers.first(where: { $0.uid == device.uid }) {
                details.append("Placed at \(SurroundCardInfo.angleTag(Double(placed.azimuth)))")
            }
            return AssignRow(
                uid: device.uid, name: device.name, suffix: device.uidSuffix,
                details: details, isSelected: device.uid == selection,
                canPlayTone: canPlayTone(uid: device.uid))
        }
        var title = "Add a speaker"
        if let uid = target.replacedUID, let replaced = speakers.first(where: { $0.uid == uid }) {
            title = "Choose the \(SurroundCardInfo.title(forAzimuth: Double(replaced.azimuth))) speaker"
        }
        return AssignSheetState(
            position: .frontLeft, rows: rows,
            footnote: showsGripPairingHint ? Self.gripPairingHint : nil,
            customTitle: title,
            confirmTitle: target == .add ? "Add Speaker" : "Use This Speaker")
    }

    /// Confirms the Surround Choose Speaker sheet. Adding a speaker that is
    /// already placed does nothing; choosing one that is placed elsewhere
    /// swaps the two.
    func confirmSurroundAssign(_ uid: String, target: SurroundAssignTarget) {
        let speakers = surroundSpeakers
        switch target {
        case .add:
            guard !speakers.contains(where: { $0.uid == uid }) else { return }
            addSurroundSpeaker(uid: uid)
        case .replace(let old):
            guard uid != old, let current = speakers.first(where: { $0.uid == old }) else { return }
            if let other = speakers.first(where: { $0.uid == uid }) {
                moveSurroundSpeaker(uid: uid, azimuth: current.azimuth, distance: current.distance)
                moveSurroundSpeaker(uid: old, azimuth: other.azimuth, distance: other.distance)
            } else {
                // One set change keeps the index and rebuilds routing once.
                changeSurroundSet(speakers.map { $0.uid == old ? uid : $0.uid })
                moveSurroundSpeaker(uid: uid, azimuth: current.azimuth, distance: current.distance)
            }
        }
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
            if routingMode == .surround { return isSurroundAvailable ? "Surround" : "Surround: add speakers" }
            return engine.swapSides ? "Playing, sides swapped" : "Playing"
        case .degraded(.monoFallback): return "Mono fallback"
        case .degraded(.quadFallback): return "Surround, some speakers missing"
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
