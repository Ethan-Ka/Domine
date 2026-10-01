/// The Choose Speaker sheet (docs/mockups/Assign.dc.html).
extension AppModel {
    static let assignToneDuration: Duration = .milliseconds(1500)

    func openAssign(_ position: SpeakerPosition) {
        guard position.isFront else { return }
        assignSelection = uid(at: position)
        assignPosition = position
    }

    /// Puts `uid` at a front position. Picking the device that is on the
    /// other side swaps the two.
    func assign(_ uid: String, to position: SpeakerPosition) {
        switch position {
        case .frontLeft:
            setSpeakers(left: uid, right: uid == rightUID ? leftUID : rightUID)
        case .frontRight:
            setSpeakers(left: uid == leftUID ? rightUID : leftUID, right: uid)
        case .rearLeft, .rearRight:
            break
        }
    }

    /// Any connected output can play its identification tone.
    func canPlayTone(uid: String) -> Bool {
        catalog.device(uid: uid) != nil
    }

    /// Through the engine when the device is one of the two routed speakers,
    /// otherwise directly on that device.
    func playAssignTone(uid: String) {
        guard canPlayTone(uid: uid) else { return }
        if engine.state == .running, uid == leftUID || uid == rightUID {
            playTones([(uid == leftUID ? .left : .right, Self.assignToneDuration)])
        } else {
            tones.play(uid: uid)
        }
    }

    func assignSheetState(for position: SpeakerPosition) -> AssignSheetState {
        let other: SpeakerPosition = position == .frontLeft ? .frontRight : .frontLeft
        let otherUID = uid(at: other)
        let rows = catalog.outputs.map { device in
            var details = [device.transportName]
            if device.uid == otherUID { details.append("In use as \(other.title)") }
            return AssignRow(
                uid: device.uid, name: device.name, suffix: device.uidSuffix,
                details: details, isSelected: device.uid == assignSelection,
                canPlayTone: canPlayTone(uid: device.uid))
        }
        return AssignSheetState(
            position: position, note: nil, rows: rows,
            footnote: catalog.showsGripPairingHint ? Self.gripPairingHint : nil)
    }

    func assignSheetActions(for position: SpeakerPosition) -> AssignSheetActions {
        AssignSheetActions(
            select: { [weak self] in self?.assignSelection = $0 },
            playTone: { [weak self] in self?.playAssignTone(uid: $0) },
            cancel: { [weak self] in self?.assignPosition = nil },
            confirm: { [weak self] uid in
                self?.assign(uid, to: position)
                self?.assignPosition = nil
            })
    }
}
