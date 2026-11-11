/// Settings > Advanced (docs/IDEAS.md customizability 4, 5, 8, 9, 13),
/// backed by `SettingsStore.advanced`.
extension AppModel {
    /// Pushes every advanced setting to the parts that use it. Runs at
    /// launch and after each change.
    func applyAdvancedSettings() {
        let s = advancedSettings
        engine.keepAliveParams = KeepAliveParams(
            holdSeconds: s.keepAliveIdleSeconds, frequencyHz: s.keepAliveHz, amplitude: s.keepAliveAmplitude)
        if !engine.state.isRouting { engine.clockSpeakerUID = s.clockSpeakerUID }
        calibration.recordSeconds = s.calibrationRecordSeconds
        calibration.maxExtraAttempts = s.calibrationExtraAttempts
        calibration.startGain = s.calibrationStartVolume
        reconnector.timing = s.reconnectTiming
        VolumeHUDPanel.shared.visibleDuration = .milliseconds(Int((s.volumeHUDSeconds * 1000).rounded()))
    }

    /// Saves the change and applies it. A new clock speaker rebuilds a
    /// running route once; a lower maximum volume pulls the master down.
    func advancedSettingsDidChange(from old: AdvancedSettings) {
        // Setting the property inside its own didSet does not call didSet again.
        let clean = advancedSettings.sanitized()
        if clean != advancedSettings { advancedSettings = clean }
        guard clean != old else { return }
        store.advanced = clean
        applyAdvancedSettings()
        if clean.clockSpeakerUID != old.clockSpeakerUID {
            clockChangeTask = Task { await engine.setClockSpeaker(clean.clockSpeakerUID) }
        }
        if clean.maxVolume != old.maxVolume, pairSettings.masterVolume > maxMasterVolume {
            updatePairSettings { $0.masterVolume = maxMasterVolume }
        }
        if clean.offsetRangeDb != old.offsetRangeDb || clean.maxVolume != old.maxVolume {
            applyPairSettingsToEngine()
        }
    }

    func restoreAdvancedDefaults() {
        advancedSettings = AdvancedSettings()
    }

    /// Timing reference choices: the connected speakers of the current
    /// mode, plus the saved one when it is not among them.
    var clockSpeakerChoices: [AdvancedClockChoice] {
        let connected = assignedSpeakerUIDs.filter { catalog.device(uid: $0) != nil }
        var seen = Set<String>()
        var choices = connected.filter { seen.insert($0).inserted }.map {
            AdvancedClockChoice(uid: $0, name: clockSpeakerLabel(uid: $0))
        }
        if let saved = advancedSettings.clockSpeakerUID, !seen.contains(saved) {
            choices.append(AdvancedClockChoice(uid: saved, name: speakerName(uid: saved), isAvailable: false))
        }
        return choices
    }

    /// Position and name with the UID suffix, since two speakers can share a name.
    private func clockSpeakerLabel(uid: String) -> String {
        switch routingMode {
        case .surround: calibrationLabel(uid: uid)
        case .single: speakerName(uid: uid)
        case .stereo: "\(uid == leftUID ? "Left" : "Right"): \(speakerName(uid: uid))"
        }
    }
}
