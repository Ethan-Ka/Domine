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
            let outcome = await self.calibration.run(kernelRate: rate, setSilent: { engine.muted = $0 || wasMuted }) {
                engine.calibrationChirps = $0
            }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .measured(let offset, let levels):
                self.applyCalibration(offsetMs: offset, levels: levels)
            case .failed(let reason):
                self.calibrationStatus = .failed(reason)
            case .microphoneDenied:
                self.calibrationStatus = .failed("Microphone access is off", offersPrivacySettings: true)
            case .tooNoisy:
                self.calibrationStatus = .failed(CalibrationOutcome.tooNoisyMessage)
            case .speakerTooQuiet(let rising):
                self.calibrationStatus = .failed(self.tooQuietMessage(uid: rising ? self.leftUID : self.rightUID))
            }
        }
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
        let name = catalog.device(uid: uid)?.name ?? "Speaker"
        let suffix = catalog.device(uid: uid)?.uidSuffix ?? OutputDevice.suffix(forUID: uid)
        return "\(name) (\(suffix)) was too quiet to measure. Turn it up and try again."
    }

    func openMicrophoneSettings() {
        services.openURL(CalibrationController.privacySettingsURL)
    }
}
