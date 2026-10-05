/// Surround auto-calibration (SPEC section 12): a ring of pairs.
extension AppModel {
    /// The closure error a ring may have before the run is rejected, in ms.
    static let ringClosureLimitMs = 2.0

    /// With present speakers s0...s(N-1) in list order, measures the pairs
    /// (s0, s1), (s1, s2), ..., (s(N-1), s0): run k plays the rising chirp on
    /// s_k and the falling one on s(k+1), giving
    /// d_k = arrival(s(k+1)) - arrival(s_k). The offsets are written only
    /// when every pair succeeds and the ring closes.
    func autoCalibrateSurround() {
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
            let speakers = self.engine.surroundPresentSpeakers
            guard speakers.count >= 3 else {
                self.calibrationStatus = .failed("Needs three connected speakers")
                return
            }
            self.cancelTone()
            let engine = self.engine
            let count = speakers.count
            var deltas: [Double] = []
            for k in 0..<count {
                guard !Task.isCancelled else { return }
                self.calibrationStatus = .measuringPair(k + 1, of: count)
                let pair = Engine.SurroundCalibrationPair(rising: speakers[k].index,
                                                          falling: speakers[(k + 1) % count].index)
                let outcome = await self.calibration.run(kernelRate: rate) { on in
                    engine.surroundCalibrationPair = on ? pair : nil
                }
                engine.surroundCalibrationPair = nil
                guard !Task.isCancelled else { return }
                switch outcome {
                case .measured(let delta):
                    deltas.append(delta)
                case .failed(let reason):
                    let a = self.calibrationLabel(uid: speakers[k].uid)
                    let b = self.calibrationLabel(uid: speakers[(k + 1) % count].uid)
                    self.calibrationStatus = .failed("\(a) and \(b): \(reason)")
                    return
                case .microphoneDenied:
                    self.calibrationStatus = .failed("Microphone access is off", offersPrivacySettings: true)
                    return
                }
            }
            guard let offsets = Self.ringOffsets(pairDeltasMs: deltas) else {
                self.calibrationStatus = .failed("Results varied. Move the Mac and try again.")
                return
            }
            self.applySurroundCalibration(uids: speakers.map { $0.uid }, offsetsMs: offsets)
        }
    }

    /// Offsets in ms (0...300) per ring speaker from the pair deltas, or nil
    /// when the ring does not close within `ringClosureLimitMs`. The closure
    /// error is spread evenly over the pairs; the latest speaker gets 0.
    static func ringOffsets(pairDeltasMs deltas: [Double]) -> [Double]? {
        let count = deltas.count
        guard count >= 2, deltas.allSatisfy(\.isFinite) else { return nil }
        let closure = deltas.reduce(0, +)
        guard abs(closure) <= ringClosureLimitMs else { return nil }
        let corrected = deltas.map { $0 - closure / Double(count) }
        var arrivals = [0.0]
        for k in 0..<(count - 1) { arrivals.append(arrivals[k] + corrected[k]) }
        let latest = arrivals.max() ?? 0
        let limit = Double(PairSettings.delayLimitMs)
        return arrivals.map { min(max(latest - $0, 0), limit) }
    }

    /// Writes every offset at once and marks the timing as measured (SPEC 13.4).
    func applySurroundCalibration(uids: [String], offsetsMs: [Double]) {
        updateSurroundSettings { s in
            for (uid, ms) in zip(uids, offsetsMs) { s.offsetsMs[uid] = Float(ms) }
            s.timingMeasured = true
        }
        calibrationStatus = .done("Delays set for \(uids.count) speakers.")
    }

    /// Reset in Surround Sync & Balance: every trim and offset back to
    /// default, and the timing no longer counts as measured.
    func resetSurroundTuning() {
        updateSurroundSettings { s in
            s.trims = [:]
            s.offsetsMs = [:]
            s.timingMeasured = false
        }
    }

    /// "Front Left 1A2B": the card title plus the UID suffix, since every
    /// speaker may be called "JBL Grip".
    func calibrationLabel(uid: String) -> String {
        let suffix = catalog.device(uid: uid)?.uidSuffix ?? OutputDevice.suffix(forUID: uid)
        guard let speaker = surroundSpeakers.first(where: { $0.uid == uid }) else {
            return [catalog.device(uid: uid)?.name ?? "Speaker", suffix].joined(separator: " ")
        }
        return "\(SurroundCardInfo.title(forAzimuth: Double(speaker.azimuth))) \(suffix)"
    }
}
