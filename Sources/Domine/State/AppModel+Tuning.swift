/// The Sync & Balance sheet (docs/mockups/Tuning.dc.html). Every change is
/// saved for the current pair and reaches the kernel at once.
extension AppModel {
    var tuningState: TuningState {
        TuningState(
            delayMs: Int(pairSettings.delayMs.rounded()),
            isExtendedRange: pairSettings.extendedRange,
            balance: Double(pairSettings.balance),
            reportedLatencies: reportedLatencyText,
            isClickTestPlaying: engine.clickTest,
            isClickTestAvailable: engine.state != .starting && engine.state != .stopping,
            clickTestMessage: clickTestMessage)
    }

    var tuningActions: TuningActions {
        TuningActions(
            setDelayMs: { [weak self] in self?.setDelayMs($0) },
            setExtendedRange: { [weak self] in self?.setExtendedRange($0) },
            setBalance: { [weak self] in self?.setBalance($0) },
            playClickTest: { [weak self] in self?.toggleClickTest() },
            autoCalibrate: nil,
            reset: { [weak self] in self?.resetTuning() },
            done: { [weak self] in self?.showsTuning = false })
    }

    func openTuning() {
        reportedLatencyText = readReportedLatencies()
        clickTestMessage = nil
        showsTuning = true
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
    private var routingFailureText: String {
        if let refusal = routingRefusal { return refusal }
        if let reason = engine.idleReason { return reason.description }
        return Self.routingErrorMessage
    }

    func setDelayMs(_ ms: Int) {
        let range = pairSettings.extendedRange ? TuningState.extendedRange : TuningState.normalRange
        updatePairSettings { $0.delayMs = Float(min(max(ms, range.lowerBound), range.upperBound)) }
    }

    /// Turning the extended range off pulls the delay back into -50...50 ms.
    func setExtendedRange(_ on: Bool) {
        updatePairSettings { s in
            s.extendedRange = on
            if !on {
                let limit = Float(TuningState.normalRange.upperBound)
                s.delayMs = min(max(s.delayMs, -limit), limit)
            }
        }
    }

    func setBalance(_ balance: Double) {
        updatePairSettings { $0.balance = Float(balance) }
    }

    /// Delay, range, and balance back to defaults. Master volume is not part of the sheet.
    func resetTuning() {
        updatePairSettings { s in
            let volume = s.masterVolume
            s = PairSettings()
            s.masterVolume = volume
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
