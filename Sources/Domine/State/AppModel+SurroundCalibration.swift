import Foundation

/// Surround auto-calibration (SPEC section 12): a ring of pairs.
extension AppModel {
    /// The closure error each pair may add before the run is rejected, in ms.
    /// Bluetooth latency wobbles by a few ms per measurement, and speakers of
    /// different models can be 80 ms or more apart, so the limit grows with
    /// the number of pairs. The error is spread evenly, so each speaker ends
    /// within closure / N of its true offset.
    static let ringClosureLimitPerPairMs = 3.0

    static func ringClosureLimitMs(pairs: Int) -> Double {
        ringClosureLimitPerPairMs * Double(pairs)
    }

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
            let speakers = self.engine.surroundPresentSpeakers
            guard speakers.count >= Self.surroundMinimumSpeakers else {
                self.calibrationStatus = .failed("Needs two connected speakers")
                return
            }
            self.cancelTone()
            let engine = self.engine
            let count = speakers.count
            var deltas: [Double] = []
            // nil once any pair comes back without levels.
            var levelDeltas: [Double]? = []
            for k in 0..<count {
                guard !Task.isCancelled else { return }
                self.calibrationStatus = .measuringPair(k + 1, of: count)
                let pair = Engine.SurroundCalibrationPair(rising: speakers[k].index,
                                                          falling: speakers[(k + 1) % count].index)
                let wasMuted = engine.muted
                let outcome = await self.calibration.run(kernelRate: rate, label: "pair\(k + 1)",
                                                         setSilent: { engine.muted = $0 || wasMuted }) { on in
                    engine.surroundCalibrationPair = on ? pair : nil
                }
                engine.surroundCalibrationPair = nil
                guard !Task.isCancelled else { return }
                switch outcome {
                case .measured(let delta, let levels):
                    deltas.append(delta)
                    if let levels, levels.rising > 0, levels.falling > 0 {
                        levelDeltas?.append(levels.fallingOverRisingDb)
                    } else {
                        levelDeltas = nil
                    }
                case .failed(let reason):
                    let a = self.calibrationLabel(uid: speakers[k].uid)
                    let b = self.calibrationLabel(uid: speakers[(k + 1) % count].uid)
                    self.calibrationStatus = .failed("\(a) and \(b): \(reason)")
                    return
                case .microphoneDenied:
                    self.calibrationStatus = .failed("Microphone access is off", offersPrivacySettings: true)
                    return
                case .tooNoisy:
                    self.calibrationStatus = .failed(CalibrationOutcome.tooNoisyMessage)
                    return
                case .speakerTooQuiet(let rising):
                    let uid = rising ? speakers[k].uid : speakers[(k + 1) % count].uid
                    self.calibrationStatus = .failed(self.tooQuietMessage(uid: uid))
                    return
                }
            }
            guard let offsets = Self.ringOffsets(pairDeltasMs: deltas) else {
                self.calibrationStatus = .failed("Results varied. Move the Mac and try again.")
                return
            }
            let trims = levelDeltas.flatMap { Self.ringTrims(pairLevelDeltasDb: $0) }
            self.applySurroundCalibration(uids: speakers.map { $0.uid }, offsetsMs: offsets, trims: trims)
        }
    }

    /// Trims per ring speaker from the pair level differences
    /// level(s(k+1)) - level(s_k) in dB, or nil if any is not finite. Levels
    /// are chained around the ring like the arrivals (closure error spread
    /// evenly), then every speaker is cut to the quietest one
    /// (`ChirpLevels.trims`): the quietest gets 1, the floor is -20 dB.
    static func ringTrims(pairLevelDeltasDb deltas: [Double]) -> [Double]? {
        let count = deltas.count
        guard count >= 2, deltas.allSatisfy(\.isFinite) else { return nil }
        let closure = deltas.reduce(0, +)
        let corrected = deltas.map { $0 - closure / Double(count) }
        var levelsDb = [0.0]
        for k in 0..<(count - 1) { levelsDb.append(levelsDb[k] + corrected[k]) }
        let quietest = levelsDb.min() ?? 0
        return levelsDb.map { max(pow(10, (quietest - $0) / 20), ChirpLevels.minTrim) }
    }

    /// Offsets in ms (0...300) per ring speaker from the pair deltas, or nil
    /// when the ring does not close within `ringClosureLimitMs(pairs:)`. The closure
    /// error is spread evenly over the pairs; the latest speaker gets 0.
    static func ringOffsets(pairDeltasMs deltas: [Double]) -> [Double]? {
        let count = deltas.count
        guard count >= 2, deltas.allSatisfy(\.isFinite) else { return nil }
        let closure = deltas.reduce(0, +)
        guard abs(closure) <= ringClosureLimitMs(pairs: count) else {
            log.info("Ring closure \(closure, privacy: .public) ms over the limit")
            return nil
        }
        let corrected = deltas.map { $0 - closure / Double(count) }
        var arrivals = [0.0]
        for k in 0..<(count - 1) { arrivals.append(arrivals[k] + corrected[k]) }
        let latest = arrivals.max() ?? 0
        let limit = Double(PairSettings.delayLimitMs)
        return arrivals.map { min(max(latest - $0, 0), limit) }
    }

    /// Writes every offset at once and marks the timing as measured; with
    /// `trims`, also every trim, marking the levels as measured (SPEC 13.4).
    func applySurroundCalibration(uids: [String], offsetsMs: [Double], trims: [Double]? = nil) {
        updateSurroundSettings { s in
            for (uid, ms) in zip(uids, offsetsMs) { s.offsetsMs[uid] = Float(ms) }
            s.timingMeasured = true
            if let trims, trims.count == uids.count {
                for (uid, trim) in zip(uids, trims) { s.trims[uid] = Float(trim) }
                s.levelMeasured = true
            }
        }
        let levels = trims?.count == uids.count
        calibrationStatus = .done("\(levels ? "Delays and levels" : "Delays") set for \(uids.count) speakers.")
    }

    /// Reset in Surround Sync & Balance: every trim and offset back to
    /// default, and neither timing nor levels count as measured.
    func resetSurroundTuning() {
        updateSurroundSettings { s in
            s.trims = [:]
            s.offsetsMs = [:]
            s.timingMeasured = false
            s.levelMeasured = false
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
