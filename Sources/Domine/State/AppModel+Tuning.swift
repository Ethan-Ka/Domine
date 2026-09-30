/// The Sync & Balance sheet (docs/mockups/Tuning.dc.html). Every change is
/// saved for the current pair and reaches the kernel at once.
extension AppModel {
    /// Click test: left, a short gap, then right.
    static let clickTestSteps: [(TestTone, Duration)] = [
        (.left, .milliseconds(300)),
        (.off, .milliseconds(200)),
        (.right, .milliseconds(300)),
    ]

    var tuningState: TuningState {
        TuningState(
            delayMs: Int(pairSettings.delayMs.rounded()),
            isExtendedRange: pairSettings.extendedRange,
            balance: Double(pairSettings.balance),
            reportedLatencies: reportedLatencyText,
            isClickTestAvailable: engine.state == .running)
    }

    var tuningActions: TuningActions {
        TuningActions(
            setDelayMs: { [weak self] in self?.setDelayMs($0) },
            setExtendedRange: { [weak self] in self?.setExtendedRange($0) },
            setBalance: { [weak self] in self?.setBalance($0) },
            playClickTest: { [weak self] in self?.playTones(Self.clickTestSteps) },
            autoCalibrate: nil,
            reset: { [weak self] in self?.resetTuning() },
            done: { [weak self] in self?.showsTuning = false })
    }

    func openTuning() {
        reportedLatencyText = readReportedLatencies()
        showsTuning = true
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
