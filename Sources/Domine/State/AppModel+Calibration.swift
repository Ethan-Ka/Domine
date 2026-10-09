/// Auto-calibration from the Sync & Balance sheet (SPEC section 12).
extension AppModel {
    /// Starts routing if it is off, records the chirps through the built-in
    /// microphone, and writes the measured offset to the delay setting.
    /// In Surround routing with two or more speakers it measures the ring
    /// of pairs instead (`autoCalibrateSurround`).
    func autoCalibrate() {
        guard calibrationTask == nil else { return }
        if surroundRouteSpeakers != nil { return autoCalibrateSurround() }
        stopClickTest()
        calibrationStatus = .listening
        calibrationTask = Task { [weak self] in
            guard let self else { return }
            self.calibration.beginSession()
            defer {
                self.calibrationTask = nil
                self.finishCalibrationSession()
            }
            if !self.engine.state.isActive { await self.startRouting() }
            guard !Task.isCancelled else { return }
            guard self.engine.state == .running, let rate = self.engine.kernelSampleRate else {
                self.calibrationStatus = .failed(self.routingFailureText)
                return
            }
            self.cancelTone()
            let engine = self.engine
            let wasMuted = engine.muted
            let left = self.speakerName(uid: self.leftUID), right = self.speakerName(uid: self.rightUID)
            // Two recordings with the chirps swapped: the same speaker reads a
            // few dB louder through the rising template, so each speaker's
            // level is the mean of its rising and falling reading (SPEC 12).
            var gains = ChirpGains()
            var results: [(offset: Double, levels: ChirpLevels?)] = []
            for swapped in [false, true] {
                engine.calibrationChirpsSwapped = swapped
                let (outcome, used) = await self.calibration.runAdjusting(
                    kernelRate: rate, label: swapped ? "stereo-swapped" : "stereo",
                    names: swapped ? (right, left) : (left, right),
                    gains: swapped ? ChirpGains(rising: gains.falling, falling: gains.rising) : gains,
                    setGains: { engine.calibrationChirpGains = $0 },
                    onRetry: { self.calibrationStatus = .adjustingVolume },
                    setSilent: { engine.muted = $0 || wasMuted }) {
                    engine.calibrationChirps = $0
                }
                engine.calibrationChirpsSwapped = false
                engine.calibrationChirpGains = ChirpGains()
                gains = swapped ? ChirpGains(rising: used.falling, falling: used.rising) : used
                guard !Task.isCancelled else { return }
                guard case .measured(let offset, let levels) = outcome else {
                    self.reportStereoFailure(outcome, leftRising: !swapped)
                    return
                }
                results.append((offset, levels))
            }
            // Run 2 measures arrival(left) - arrival(right).
            let offset = (results[0].offset - results[1].offset) / 2
            let levels = ChirpLevels.combined(leftRising: results[0].levels, rightRising: results[1].levels)
            self.applyCalibration(offsetMs: offset, levels: levels)
        }
    }

    private func reportStereoFailure(_ outcome: CalibrationOutcome, leftRising: Bool) {
        switch outcome {
        case .measured:
            break
        case .failed(let reason):
            calibrationStatus = .failed(reason)
        case .microphoneDenied:
            calibrationStatus = .failed("Microphone access is off", offersPrivacySettings: true)
        case .tooNoisy:
            calibrationStatus = .failed(CalibrationOutcome.tooNoisyMessage)
        case .overloaded:
            calibrationStatus = .failed(CalibrationOutcome.overloadedMessage)
        case .speakerTooQuiet(let rising):
            calibrationStatus = .failed(tooQuietMessage(uid: rising == leftRising ? leftUID : rightUID))
        }
    }

    /// "JBL Grip (1A2B)" for the calibration log.
    func speakerName(uid: String?) -> String {
        guard let uid else { return "Speaker" }
        let name = catalog.device(uid: uid)?.name ?? "Speaker"
        let suffix = catalog.device(uid: uid)?.uidSuffix ?? OutputDevice.suffix(forUID: uid)
        return "\(name) (\(suffix))"
    }

    /// Hands the run's recordings to the archive: kept only when it failed,
    /// the folder emptied when it succeeded, untouched when cancelled.
    func finishCalibrationSession() {
        var failed = false
        if case .failed? = calibrationStatus { failed = true }
        calibration.endSession(failed: failed, cancelled: Task.isCancelled)
    }

    func cancelCalibration() {
        calibrationTask?.cancel()
        calibrationTask = nil
        if engine.calibrationChirps { engine.calibrationChirps = false }
        engine.calibrationChirpsSwapped = false
        engine.calibrationChirpGains = ChirpGains()
        if engine.surroundCalibrationPair != nil { engine.surroundCalibrationPair = nil }
        if calibrationStatus?.isInProgress == true { calibrationStatus = nil }
    }

    /// offset = arrival(right) - arrival(left). Saved through the same path
    /// as the slider, widening to the extended range when needed.
    /// With `levels` (left plays the rising chirp, right the falling one),
    /// also sets the balance so the louder speaker is cut to the quieter one.
    func applyCalibration(offsetMs offset: Double, levels: ChirpLevels? = nil) {
        let limit = TuningState.extendedRange.upperBound
        let ms = min(max(CalibrationAnalyzer.delaySetting(forOffsetMs: offset), -limit), limit)
        if !TuningState.normalRange.contains(ms) { setExtendedRange(true) }
        setDelayMs(ms)
        let balance = levels.flatMap { Self.calibratedBalance(levels: $0) }
        if let balance { setBalance(balance) }
        let what = balance == nil ? "Delay set." : "Delay and balance set."
        let late = Int(abs(offset).rounded())
        if late == 0 {
            calibrationStatus = .done("Speakers are in sync. \(what)")
        } else {
            calibrationStatus = .done("\(offset > 0 ? "Right" : "Left") was \(late) ms late. \(what)")
        }
    }

    /// The balance that cuts the louder speaker to the quieter one's level
    /// (`ChirpLevels.trims`): positive lowers the left, negative the right.
    /// Nil when either level is unusable.
    nonisolated static func calibratedBalance(levels: ChirpLevels) -> Double? {
        let trims = ChirpLevels.trims(levels: ["L": levels.rising, "R": levels.falling])
        guard let left = trims["L"], let right = trims["R"] else { return nil }
        return right < 1 ? -(1 - right) : 1 - left
    }

    /// "JBL Go 4 (7146) was too quiet to measure. Turn it up and try again."
    /// Name plus UID suffix, since two speakers may share a name.
    func tooQuietMessage(uid: String?) -> String {
        guard let uid else { return "A speaker was too quiet to measure. Turn it up and try again." }
        return "\(speakerName(uid: uid)) was too quiet to measure. Turn it up and try again."
    }

    func openMicrophoneSettings() {
        services.openURL(CalibrationController.privacySettingsURL)
    }
}
