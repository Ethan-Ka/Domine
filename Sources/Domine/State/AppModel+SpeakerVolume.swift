/// Per-speaker hardware volume offsets (SPEC 4a), for mixing speakers that
/// play at different loudness at the same volume setting.
extension AppModel {
    /// Offset in dB per speaker UID for the current mode: the surround
    /// record in Surround, the pair's left and right otherwise.
    /// Each is clamped to the offset range in Settings > Advanced; the
    /// saved value is kept, so widening the range brings it back.
    var speakerVolumeOffsets: [String: Float] {
        let limit = speakerVolumeOffsetLimitDb
        if routingMode == .surround { return surroundSettings.volumeOffsetsDb.mapValues { min(max($0, -limit), limit) } }
        var offsets: [String: Float] = [:]
        if let left = leftUID { offsets[left] = min(max(pairSettings.leftVolumeOffsetDb, -limit), limit) }
        if let right = rightUID, right != leftUID {
            offsets[right] = min(max(pairSettings.rightVolumeOffsetDb, -limit), limit)
        }
        return offsets
    }

    /// Offsets go from minus to plus this many dB (Settings > Advanced).
    var speakerVolumeOffsetLimitDb: Float {
        min(Float(advancedSettings.offsetRangeDb), SpeakerVolumeLink.offsetRange.upperBound)
    }

    /// False only for a present speaker whose volume Domine cannot set.
    func canSetHardwareVolume(uid: String) -> Bool {
        volumeLink.attachedDevices[uid] == nil || volumeLink.hasHardwareVolume(uid: uid)
    }

    /// Stores the offset with the speaker's tuning. A speaker without
    /// settable hardware volume only takes a cut: Domine never adds digital gain.
    func setSpeakerVolumeOffset(uid: String, db: Float) {
        guard db.isFinite else { return }
        let limit = speakerVolumeOffsetLimitDb
        var value = min(max(db, -limit), limit)
        if !canSetHardwareVolume(uid: uid) { value = min(value, 0) }
        if routingMode == .surround {
            guard surroundSpeakers.contains(where: { $0.uid == uid }) else { return }
            updateSurroundSettings { $0.volumeOffsetsDb[uid] = value == 0 ? nil : value }
        } else if uid == leftUID {
            updatePairSettings { $0.leftVolumeOffsetDb = value }
        } else if uid == rightUID {
            updatePairSettings { $0.rightVolumeOffsetDb = value }
        }
    }

    func speakerVolumeRow(uid: String, title: String) -> SpeakerVolumeRow {
        SpeakerVolumeRow(
            uid: uid,
            title: title,
            suffix: catalog.device(uid: uid)?.uidSuffix ?? OutputDevice.suffix(forUID: uid),
            offsetDb: Double(speakerVolumeOffsets[uid] ?? 0),
            isAtMaximum: volumeLink.isAtMaximum(uid: uid),
            hasHardwareVolume: canSetHardwareVolume(uid: uid),
            limitDb: Double(speakerVolumeOffsetLimitDb))
    }

    /// Stereo rows for Sync & Balance: Left, then Right. Single has one row.
    var stereoSpeakerVolumeRows: [SpeakerVolumeRow] {
        if routingMode == .single {
            return leftUID.map { [speakerVolumeRow(uid: $0, title: Self.singleSpeakerTitle)] } ?? []
        }
        guard let left = leftUID, let right = rightUID, left != right else { return [] }
        return [speakerVolumeRow(uid: left, title: "Left"), speakerVolumeRow(uid: right, title: "Right")]
    }
}
