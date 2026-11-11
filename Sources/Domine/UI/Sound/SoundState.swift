import Foundation

/// Everything the Sound sheet shows.
struct SoundState: Equatable, Sendable {
    typealias Effects = PairSettings.EffectsSettings
    typealias Side = PairSettings.SideEffects

    var effects = Effects()
    var crossfeed = 0.0
    var sameOnBoth = false
    /// Set in Surround mode: every speaker's effects and the link.
    var surround: SurroundSound?

    typealias Band = PairSettings.SideEffects.Band

    static let gainRange: ClosedRange<Float> = PairSettings.SideEffects.gainRange

    /// "80 Hz", "1 kHz", "12.5 kHz".
    static func frequencyLabel(_ hz: Float) -> String {
        if hz < 1000 { return "\(Int(hz.rounded())) Hz" }
        let k = (Double(hz) / 100).rounded() / 10
        return "\(k.formatted(.number.precision(.fractionLength(0...1)))) kHz"
    }

    /// "Q 0.7", "Q 1", "Q 2.25".
    static func qLabel(_ q: Float) -> String {
        "Q \(Double(q).formatted(.number.precision(.fractionLength(0...2))))"
    }

    /// "+3 dB", "0 dB", "-3 dB".
    static func gainLabel(_ db: Float) -> String {
        let v = Int(db.rounded())
        return v > 0 ? "+\(v) dB" : "\(v) dB"
    }

    /// A new peak band in the widest gap (on a log scale) between the
    /// existing bands and the ends of the range, kept in frequency order.
    /// Unchanged at the band limit.
    static func addingBand(to bands: [Band]) -> [Band] {
        guard bands.count < PairSettings.SideEffects.maxBands else { return bands }
        let range = PairSettings.SideEffects.freqRange
        let edges = [range.lowerBound] + bands.map(\.freqHz).sorted() + [range.upperBound]
        var best = (lo: edges[0], hi: edges[1])
        for i in 1..<edges.count where log(edges[i] / edges[i - 1]) > log(best.hi / best.lo) {
            best = (edges[i - 1], edges[i])
        }
        let hz = (sqrt(best.lo * best.hi)).rounded()
        var out = bands
        let at = out.firstIndex { $0.freqHz > hz } ?? out.count
        out.insert(Band(freqHz: hz), at: at)
        return out
    }

    /// Bands with one removed; the last band cannot be removed.
    static func removingBand(at index: Int, from bands: [Band]) -> [Band] {
        guard bands.count > 1, bands.indices.contains(index) else { return bands }
        var out = bands
        out.remove(at: index)
        return out
    }

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
