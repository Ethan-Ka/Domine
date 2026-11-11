/// Per-speaker role and the shared crossover (Sync & Balance). Stereo keeps
/// them in the pair's settings (left and right as assigned now), Surround in
/// the set's record by UID.
extension AppModel {
    /// One row per speaker in the order Sync & Balance lists them. Empty in
    /// Single mode, where the one speaker always plays the whole range.
    var speakerRoleRows: [SpeakerRoleRow] {
        if routingMode == .surround {
            let settings = surroundSettings
            return settings.speakers.map { speaker in
                roleRow(uid: speaker.uid, title: SurroundCardInfo.title(forAzimuth: Double(speaker.azimuth)),
                        role: settings.role(for: speaker.uid))
            }
        }
        guard routingMode != .single, let left = leftUID, let right = rightUID, left != right else { return [] }
        return [roleRow(uid: left, title: "Left", role: pairSettings.leftRole),
                roleRow(uid: right, title: "Right", role: pairSettings.rightRole)]
    }

    /// The crossover of the current setup, 40...200 Hz.
    var speakerCrossoverHz: Float {
        routingMode == .surround ? surroundSettings.crossoverHz : pairSettings.crossoverHz
    }

    func setSpeakerRole(uid: String, _ role: SpeakerRole) {
        if routingMode == .surround {
            guard surroundSpeakers.contains(where: { $0.uid == uid }) else { return }
            updateSurroundSettings { $0.roles[uid] = role == .fullRange ? nil : role }
        } else if uid == leftUID {
            updatePairSettings { $0.leftRole = role }
        } else if uid == rightUID {
            updatePairSettings { $0.rightRole = role }
        }
    }

    func setSpeakerCrossover(hz: Float) {
        guard hz.isFinite else { return }
        let value = SpeakerRole.clampCrossover(hz.rounded())
        if routingMode == .surround {
            updateSurroundSettings { $0.crossoverHz = value }
        } else {
            updatePairSettings { $0.crossoverHz = value }
        }
    }

    private func roleRow(uid: String, title: String, role: SpeakerRole) -> SpeakerRoleRow {
        SpeakerRoleRow(uid: uid, title: title,
                       suffix: catalog.device(uid: uid)?.uidSuffix ?? OutputDevice.suffix(forUID: uid),
                       role: role)
    }
}
