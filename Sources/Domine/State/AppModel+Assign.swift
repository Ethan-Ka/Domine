/// The Choose Speaker sheet (docs/mockups/Assign.dc.html).
extension AppModel {
    static let assignToneDuration: Duration = .milliseconds(1500)

    func openAssign(_ position: SpeakerPosition) {
        // Surround speakers use their own sheet (AppModel+MainWindow).
        guard position.isFront else { return }
        assignSelection = uid(at: position)
        assignPosition = position
    }

    /// Puts `uid` at a position. Picking a device that is already at another
    /// position swaps the two.
    func assign(_ uid: String, to position: SpeakerPosition) {
        var slots = SpeakerPosition.allCases.map { self.uid(at: $0) }
        let index = SpeakerPosition.allCases.firstIndex(of: position)!
        if let from = slots.firstIndex(of: uid) { slots[from] = slots[index] }
        slots[index] = uid
        setSpeakers(left: slots[0], right: slots[1])
        setRear(left: slots[2], right: slots[3])
    }

    /// Any connected output can play its identification tone.
    func canPlayTone(uid: String) -> Bool {
        catalog.device(uid: uid) != nil
    }

    /// Through the engine when the device is one of the two routed speakers,
    /// otherwise directly on that device.
    func playAssignTone(uid: String) {
        guard canPlayTone(uid: uid) else { return }
        if engine.state.isRouting, uid == leftUID || uid == rightUID {
            playTones([(uid == leftUID ? .left : .right, Self.assignToneDuration)])
        } else {
            tones.play(uid: uid)
        }
    }

    func assignSheetState(for position: SpeakerPosition) -> AssignSheetState {
        let rows = catalog.outputs.map { device in
            var details = [device.transportName]
            if let other = SpeakerPosition.allCases.first(where: { $0 != position && uid(at: $0) == device.uid }) {
                details.append("In use as \(other.title)")
            }
            return AssignRow(
                uid: device.uid, name: device.name, suffix: device.uidSuffix,
                details: details, isSelected: device.uid == assignSelection,
                canPlayTone: canPlayTone(uid: device.uid))
        }
        return AssignSheetState(
            position: position, rows: rows,
            footnote: showsGripPairingHint ? Self.gripPairingHint : nil)
    }

    func assignSheetActions(for position: SpeakerPosition) -> AssignSheetActions {
        AssignSheetActions(
            select: { [weak self] in self?.assignSelection = $0 },
            playTone: { [weak self] in self?.playAssignTone(uid: $0) },
            cancel: { [weak self] in self?.assignPosition = nil },
            confirm: { [weak self] uid in
                self?.assign(uid, to: position)
                self?.assignPosition = nil
            },
            openBluetooth: { [weak self] in self?.openBluetooth() })
    }
}
