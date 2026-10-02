/// The Sound sheet. Every change is saved and reaches the kernel at once.
/// In Surround mode the sheet edits the first speaker's effects, which every
/// speaker shares while effects are linked (SPEC 13.6).
extension AppModel {
    var soundState: SoundState {
        guard let first = surroundSoundUID else { return SoundState(effects: pairSettings.effects) }
        return SoundState(effects: PairSettings.EffectsSettings(both: surroundEffects(uid: first)))
    }

    var soundActions: SoundActions {
        SoundActions(
            setEffects: { [weak self] in self?.setSoundEffects($0) },
            reset: { [weak self] in self?.setSoundEffects(PairSettings.EffectsSettings()) },
            done: { [weak self] in self?.showsSound = false })
    }

    func openSound() { showsSound = true }

    /// The speaker the sheet edits in Surround mode; nil in Stereo.
    private var surroundSoundUID: String? {
        routingMode == .surround ? surroundSpeakers.first?.uid : nil
    }

    private func setSoundEffects(_ effects: PairSettings.EffectsSettings) {
        if let first = surroundSoundUID {
            setSurroundEffects(uid: first, effects.left)
        } else {
            setEffects(effects)
        }
    }
}
