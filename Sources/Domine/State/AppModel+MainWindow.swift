/// Main window state and actions (docs/mockups/Main.dc.html).
extension AppModel {
    static let gripPairingHint = "Only one JBL Grip found. Turn off stereo pairing in the JBL Portable app."

    var mainWindowState: MainWindowState {
        MainWindowState(
            statusLine: statusLine,
            isOn: engine.state.isActive,
            canSwap: true,
            speakers: [
                card(for: .frontLeft),
                card(for: .frontRight),
                .placeholder(.rearLeft),
                .placeholder(.rearRight),
            ],
            masterVolume: Double(pairSettings.masterVolume),
            isMuted: isMuted,
            testToneSide: testToneSide,
            canPlayTestTones: engine.state == .running
                || [leftUID, rightUID].contains { $0.flatMap(catalog.device(uid:)) != nil },
            bannerMessage: catalog.showsGripPairingHint ? Self.gripPairingHint : nil)
    }

    var mainWindowActions: MainWindowActions {
        MainWindowActions(
            setOn: { [weak self] in self?.setRouting($0) },
            setMode: { _ in },
            swap: { [weak self] in self?.swapSides() },
            setMasterVolume: { [weak self] volume in
                // Moving the slider unmutes, as the system volume slider does.
                self?.setMasterVolume(volume)
                self?.setMuted(false)
            },
            toggleTestTone: { [weak self] in self?.toggleTestTone($0) },
            selectSpeaker: { [weak self] in self?.openAssign($0) },
            openTuning: { [weak self] in self?.openTuning() })
    }

    /// One short phrase for the window subtitle.
    var statusLine: String {
        switch engine.state {
        case .idle:
            if leftUID == nil || rightUID == nil { return "Choose two speakers" }
            return routingRefusal ?? engine.idleReason?.description ?? "Off"
        case .starting: return "Starting"
        case .running:
            if volumeKeysNeedAccessibility { return "Playing, volume keys need Accessibility access" }
            return engine.swapSides ? "Playing, sides swapped" : "Playing"
        case .stopping: return "Stopping"
        case .error(let message): return message
        }
    }

    /// Test tones are positional: left is position A, the Front Left card.
    private var testToneSide: StereoSide? {
        if engine.state != .running, let playing = tones.playingUID {
            return playing == leftUID ? .left : playing == rightUID ? .right : nil
        }
        return switch engine.testTone {
        case .off: nil
        case .left: .left
        case .right: .right
        }
    }

    /// A front card. Front Left is always position A (the `leftUID` device);
    /// swapping only changes which channel it plays, shown by the side tag.
    func card(for position: SpeakerPosition) -> SpeakerCardState {
        guard position.isFront else { return .placeholder(position) }
        let isA = position == .frontLeft
        let tag = isA != engine.swapSides ? "L" : "R"
        guard let uid = uid(at: position) else {
            return SpeakerCardState(
                position: position, sideTag: tag, statusText: "Choose a speaker", connection: .unassigned)
        }
        guard let device = catalog.device(uid: uid) else {
            return SpeakerCardState(
                position: position, sideTag: tag,
                deviceName: knownNames[uid], uidSuffix: OutputDevice.suffix(forUID: uid),
                statusText: "Off or disconnected", connection: .disconnected)
        }
        let level = engine.state == .running ? (isA ? meters.levelA : meters.levelB) : 0
        return SpeakerCardState(
            position: position, sideTag: tag,
            deviceName: device.name, uidSuffix: device.uidSuffix,
            volumePercent: Int((pairSettings.masterVolume * 100).rounded()),
            statusText: "Connected", connection: .connected,
            level: Double(level))
    }
}
