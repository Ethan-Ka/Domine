/// The Sync & Balance sheet (docs/mockups/Tuning.dc.html). Every change is
/// saved for the current pair and reaches the kernel at once.
extension AppModel {
    var tuningState: TuningState {
        TuningState(
            delayMs: TuningState.roundedDelay(Double(pairSettings.delayMs)),
            balance: Double(pairSettings.balance),
            reportedLatencies: reportedLatencyText,
            isClickTestPlaying: engine.clickTest,
            isClickTestAvailable: engine.state != .starting && engine.state != .stopping
                && calibrationStatus?.isInProgress != true,
            clickTestMessage: clickTestMessage,
            calibrationStatus: calibrationStatus,
            calibrationUnavailableReason: isCalibrationAvailable ? nil : Self.calibrationUnavailableText,
            canUndoCalibration: calibrationUndo != nil,
            nudgeSteps: delayNudgeSteps)
    }

    static let calibrationUnavailableText = "Auto-calibrate needs the Mac's built-in microphone."

    var tuningActions: TuningActions {
        var calibrate: (@MainActor @Sendable () -> Void)?
        if isCalibrationAvailable {
            calibrate = { [weak self] in self?.autoCalibrate() }
        }
        var undo: (@MainActor @Sendable () -> Void)?
        if calibrationUndo != nil {
            undo = { [weak self] in self?.undoCalibration() }
        }
        return TuningActions(
            setDelayMs: { [weak self] in self?.setDelayMs($0) },
            setBalance: { [weak self] in self?.setBalance($0) },
            playClickTest: { [weak self] in self?.toggleClickTest() },
            autoCalibrate: calibrate,
            undoCalibration: undo,
            discardCalibrationUndo: { [weak self] in self?.calibrationUndo = nil },
            setNudgeSteps: { [weak self] in self?.setDelayNudgeSteps($0) },
            openMicrophoneSettings: { [weak self] in self?.openMicrophoneSettings() },
            reset: { [weak self] in self?.resetTuning() },
            done: { [weak self] in self?.showsTuning = false })
    }

    func openTuning() {
        reportedLatencyText = readReportedLatencies()
        clickTestMessage = nil
        calibrationStatus = nil
        calibrationUndo = nil
        isCalibrationAvailable = calibration.isAvailable
        delayNudgeSteps = store.delayNudgeSteps
        showsTuning = true
    }

    func setDelayNudgeSteps(_ steps: DelayNudgeSteps) {
        delayNudgeSteps = steps
        store.delayNudgeSteps = steps
    }

    /// Clicks on both speakers at once, through the delay line, so moving the
    /// delay slider moves one speaker's click against the other's. Starts
    /// routing first when it is off, since only the real path can be aligned.
    func toggleClickTest() {
        if engine.clickTest || clickTestTask != nil {
            stopClickTest()
            return
        }
        clickTestMessage = nil
        if engine.state == .running {
            cancelTone()
            engine.clickTest = true
            return
        }
        guard !engine.state.isActive else { return }
        clickTestTask = Task { [weak self] in
            guard let self else { return }
            await self.startRouting()
            defer { self.clickTestTask = nil }
            guard !Task.isCancelled, self.showsTuning else { return }
            guard self.engine.state == .running else {
                self.clickTestMessage = self.routingFailureText
                return
            }
            self.cancelTone()
            self.engine.clickTest = true
        }
    }

    func stopClickTest() {
        clickTestTask?.cancel()
        clickTestTask = nil
        if engine.clickTest { engine.clickTest = false }
    }

    /// One short line on why routing did not start.
    var routingFailureText: String {
        if let refusal = routingRefusal { return refusal }
        if let reason = engine.idleReason { return reason.description }
        return Self.routingErrorMessage
    }

    /// A hand edit: rounded to 0.5 ms, clamped to -300...300, and the last
    /// calibration can no longer be undone.
    func setDelayMs(_ ms: Double) {
        calibrationUndo = nil
        applyDelayMs(ms)
    }

    func setBalance(_ balance: Double) {
        calibrationUndo = nil
        applyBalance(balance)
    }

    /// `setDelayMs` without touching the undo.
    func applyDelayMs(_ ms: Double) {
        guard ms.isFinite else { return }
        let range = TuningState.delayRange
        let value = min(max(TuningState.roundedDelay(ms), range.lowerBound), range.upperBound)
        updatePairSettings { $0.delayMs = Float(value) }
    }

    func applyBalance(_ balance: Double) {
        updatePairSettings { $0.balance = Float(balance) }
    }

    /// Delay, range, and balance back to defaults. Master volume is not part
    /// of the sheet, and the speaker volume offsets describe the speakers.
    func resetTuning() {
        calibrationUndo = nil
        updatePairSettings { s in
            let old = s
            s = PairSettings()
            s.masterVolume = old.masterVolume
            s.leftVolumeOffsetDb = old.leftVolumeOffsetDb
            s.rightVolumeOffsetDb = old.rightVolumeOffsetDb
        }
    }

    /// "Reported latency: left 182 ms, right 176 ms", or nil without a pair
    /// or when neither speaker reports anything.
    func readReportedLatencies() -> String? {
        guard let left = leftUID, let right = rightUID else { return nil }
        let l = engine.reportedLatencyMs(uid: left)
        let r = engine.reportedLatencyMs(uid: right)
        guard l != nil || r != nil else { return nil }
        func text(_ ms: Double?) -> String { ms.map { "\(Int($0.rounded())) ms" } ?? "unknown" }
        return "Reported latency: left \(text(l)), right \(text(r))"
    }
}
