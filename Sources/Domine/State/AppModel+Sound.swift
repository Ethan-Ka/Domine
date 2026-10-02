/// The Sound sheet. Every change is saved for the current pair and reaches
/// the kernel at once.
extension AppModel {
    var soundState: SoundState { SoundState(effects: pairSettings.effects, quad: quadRouteUIDs == nil ? nil : quadSettings) }

    var soundActions: SoundActions {
        SoundActions(
            setEffects: { [weak self] in self?.setEffects($0) },
            setQuad: { [weak self] q in self?.setQuadRearEffects { $0 = q } },
            reset: { [weak self] in self?.setEffects(PairSettings.EffectsSettings()) },
            done: { [weak self] in self?.showsSound = false })
    }

    func openSound() { showsSound = true }
}
