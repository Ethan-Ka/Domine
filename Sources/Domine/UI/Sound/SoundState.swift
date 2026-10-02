/// Everything the Sound sheet shows.
struct SoundState: Equatable, Sendable {
    typealias Effects = PairSettings.EffectsSettings
    typealias Side = PairSettings.SideEffects

    var effects = Effects()
    /// Set in Surround mode: every speaker's effects and the link.
    var surround: SurroundSound?

    static let bandLabels = ["80", "250", "1k", "4k", "10k"]
    static let gainRange: ClosedRange<Float> = -12...12

    /// The preset the settings match, or nil when they have been edited.
    var preset: PairSettings.Preset? {
        PairSettings.Preset.allCases.first {
            let p = $0.settings.left
            return effects.left == p && effects.effectiveRight == p
        }
    }

    /// The settings of one side: left while linked.
    func side(_ side: StereoSide) -> Side {
        side == .right && !effects.linkSpeakers ? effects.right : effects.left
    }

    /// `effects` with `change` applied to the edited side, or to both while linked.
    func applying(to side: StereoSide, _ change: (inout Side) -> Void) -> Effects {
        var e = effects
        if e.linkSpeakers {
            change(&e.left)
            e.right = e.left
        } else if side == .left {
            change(&e.left)
        } else {
            change(&e.right)
        }
        return e
    }

    func setting(link: Bool) -> Effects {
        var e = effects
        e.linkSpeakers = link
        if link { e.right = e.left }
        return e
    }

    /// A preset replaces the effects but keeps the link choice.
    func applying(preset: PairSettings.Preset) -> Effects {
        var e = preset.settings
        e.linkSpeakers = effects.linkSpeakers
        return e
    }
}
