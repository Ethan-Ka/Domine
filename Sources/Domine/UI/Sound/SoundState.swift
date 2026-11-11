/// Everything the Sound sheet shows.
struct SoundState: Equatable, Sendable {
    typealias Effects = PairSettings.EffectsSettings
    typealias Side = PairSettings.SideEffects

    var effects = Effects()
    var crossfeed = 0.0
    var sameOnBoth = false
    /// Set in Surround mode: every speaker's effects and the link.
    var surround: SurroundSound?

    /// "80 Hz", "1 kHz": derived from a band's frequency so edits follow.
    static func bandLabel(freqHz: Float) -> String {
        if freqHz >= 1000 {
            let k = Double(freqHz) / 1000
            let text = k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)
            return "\(text) kHz"
        }
        return "\(Int(freqHz.rounded())) Hz"
    }

    /// "+3 dB", "0 dB", "-2 dB".
    static func gainText(_ db: Float) -> String {
        let n = Int(db.rounded())
        return n > 0 ? "+\(n) dB" : "\(n) dB"
    }
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
        return e.settingNightMode(effects.nightMode)
    }
}
