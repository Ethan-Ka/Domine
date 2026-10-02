/// Auto-calibration from the Sync & Balance sheet (SPEC section 12).
extension AppModel {
    /// Starts routing if it is off, records the chirps through the built-in
    /// microphone, and writes the measured offset to the delay setting.
    func autoCalibrate() {
        guard calibrationTask == nil else { return }
        stopClickTest()
        calibrationStatus = .listening
        calibrationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.calibrationTask = nil }
            if !self.engine.state.isActive { await self.startRouting() }
            guard !Task.isCancelled else { return }
            guard self.engine.state == .running, let rate = self.engine.kernelSampleRate else {
                self.calibrationStatus = .failed(self.routingFailureText)
                return
            }
            self.cancelTone()
            let engine = self.engine
            let outcome = await self.calibration.run(kernelRate: rate) { engine.calibrationChirps = $0 }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .measured(let offset):
                self.applyCalibration(offsetMs: offset)
            case .failed(let reason):
                self.calibrationStatus = .failed(reason)
            case .microphoneDenied:
                self.calibrationStatus = .failed("Microphone access is off", offersPrivacySettings: true)
            }
        }
    }

    func cancelCalibration() {
        calibrationTask?.cancel()
        calibrationTask = nil
        if engine.calibrationChirps { engine.calibrationChirps = false }
        if calibrationStatus == .listening { calibrationStatus = nil }
    }

    /// offset = arrival(right) - arrival(left). Saved through the same path
    /// as the slider, widening to the extended range when needed.
    func applyCalibration(offsetMs offset: Double) {
        let limit = TuningState.extendedRange.upperBound
        let ms = min(max(CalibrationAnalyzer.delaySetting(forOffsetMs: offset), -limit), limit)
        if !TuningState.normalRange.contains(ms) { setExtendedRange(true) }
        setDelayMs(ms)
        let late = Int(abs(offset).rounded())
        if late == 0 {
            calibrationStatus = .done("Speakers are in sync. Delay set.")
        } else {
            calibrationStatus = .done("\(offset > 0 ? "Right" : "Left") was \(late) ms late. Delay set.")
        }
    }

    func openMicrophoneSettings() {
        services.openURL(CalibrationController.privacySettingsURL)
    }
}
