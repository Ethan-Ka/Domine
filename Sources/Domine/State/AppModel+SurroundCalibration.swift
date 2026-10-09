import Foundation
import os

/// Surround auto-calibration (SPEC section 12): a ring of pairs.
extension AppModel {
    private static let calibrationLog = Logger(subsystem: "com.ethankawley.Domine", category: "Calibration")

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
            var pairLevels: [ChirpLevels]? = []
            // Test volume chosen per speaker UID, kept for its next pair.
            var chirpGains: [String: Double] = [:]
            for k in 0..<count {
                guard !Task.isCancelled else { return }
                self.calibrationStatus = .measuringPair(k + 1, of: count)
                let pair = Engine.SurroundCalibrationPair(rising: speakers[k].index,
                                                          falling: speakers[(k + 1) % count].index)
                let risingUID = speakers[k].uid, fallingUID = speakers[(k + 1) % count].uid
                let wasMuted = engine.muted
                let (outcome, used) = await self.calibration.runAdjusting(
                    kernelRate: rate, label: "pair\(k + 1)",
                    names: (self.calibrationLabel(uid: risingUID), self.calibrationLabel(uid: fallingUID)),
                    gains: ChirpGains(rising: chirpGains[risingUID] ?? 1, falling: chirpGains[fallingUID] ?? 1),
                    setGains: { engine.calibrationChirpGains = $0 },
                    onRetry: { self.calibrationStatus = .adjustingVolume },
                    setSilent: { engine.muted = $0 || wasMuted }) { on in
                    engine.surroundCalibrationPair = on ? pair : nil
                }
                engine.surroundCalibrationPair = nil
                engine.calibrationChirpGains = ChirpGains()
                chirpGains[risingUID] = used.rising
                chirpGains[fallingUID] = used.falling
                guard !Task.isCancelled else { return }
                switch outcome {
                case .measured(let delta, let levels):
                    deltas.append(delta)
                    if let levels, levels.rising > 0, levels.falling > 0 {
                        pairLevels?.append(levels)
                    } else {
                        pairLevels = nil
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
                case .overloaded:
                    self.calibrationStatus = .failed(CalibrationOutcome.overloadedMessage)
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
            let trims = pairLevels.flatMap { Self.ringTrims(pairLevels: $0) }
            self.applySurroundCalibration(uids: speakers.map { $0.uid }, offsetsMs: offsets, trims: trims)
        }
    }

    /// Trims per ring speaker from each pair's levels (pair k: s_k rising,
    /// s(k+1) falling, already divided by the test volume), or nil if any
    /// level is not finite and positive. The same speaker reads a few dB
    /// louder through the rising template than the falling one, so levels
    /// are never compared across templates: each speaker plays rising in
    /// pair k and falling in pair k-1, and its level is the mean of those
    /// two in dB. Then every speaker is cut to the quietest one
    /// (`ChirpLevels.trims`): the quietest gets 1, the floor is -20 dB.
    static func ringTrims(pairLevels: [ChirpLevels]) -> [Double]? {
        let count = pairLevels.count
        guard count >= 2,
              pairLevels.allSatisfy({ $0.rising.isFinite && $0.rising > 0 && $0.falling.isFinite && $0.falling > 0 })
        else { return nil }
        let levelsDb = (0..<count).map { k in
            let rising = 20 * log10(pairLevels[k].rising)
            let falling = 20 * log10(pairLevels[(k + count - 1) % count].falling)
            return (rising + falling) / 2
        }
        let quietest = levelsDb.min() ?? 0
        return levelsDb.map { max(pow(10, (quietest - $0) / 20), ChirpLevels.minTrim) }
    }

    /// Offsets in ms (0...300) per ring speaker from the pair deltas, or nil
    /// for fewer than 2 pairs or a delta that is not finite. The ring never
    /// fails for not closing: Bluetooth latency wobbles by several ms per
    /// measurement, so the closure error is logged and spread evenly over the
    /// pairs (each speaker ends within closure / N of its true offset). The
    /// latest speaker gets 0.
    static func ringOffsets(pairDeltasMs deltas: [Double]) -> [Double]? {
        let count = deltas.count
        guard count >= 2, deltas.allSatisfy(\.isFinite) else { return nil }
        let closure = deltas.reduce(0, +)
        calibrationLog.info("Ring closure \(closure, privacy: .public) ms over \(count, privacy: .public) pairs, spread evenly")
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
