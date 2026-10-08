import DomineDSP

extension PairSettings {
    /// One speaker's effects chain: EQ, bass enhancer, compressor.
    struct SideEffects: Codable, Equatable, Sendable {
        struct Band: Codable, Equatable, Sendable {
            var freqHz: Float
            var gainDb: Float
            var q: Float
            init(freqHz: Float, gainDb: Float = 0, q: Float = 1) {
                self.freqHz = freqHz
                self.gainDb = gainDb
                self.q = q
            }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.init(freqHz: (try? c.decodeIfPresent(Float.self, forKey: .freqHz)) ?? 1000,
                          gainDb: (try? c.decodeIfPresent(Float.self, forKey: .gainDb)) ?? 0,
                          q: (try? c.decodeIfPresent(Float.self, forKey: .q)) ?? 1)
            }
            private enum CodingKeys: String, CodingKey { case freqHz, gainDb, q }
        }

        static let defaultBands: [Band] = [
            Band(freqHz: 80), Band(freqHz: 250), Band(freqHz: 1000), Band(freqHz: 4000), Band(freqHz: 10_000),
        ]

        var eqEnabled = false
        /// Always 5 bands: low shelf, three peaking, high shelf.
        var eqBands = SideEffects.defaultBands
        var bassEnabled = false
        /// 0...1.
        var bassAmount: Float = 0
        var compressorEnabled = false
        /// 0...1: threshold -6...-30 dB, ratio 1.5...4, automatic makeup.
        var compressorAmount: Float = 0
        /// Overrides the compressor and adds loudness without touching the settings above.
        var nightMode = false

        init() {}

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = SideEffects()
            eqEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .eqEnabled)) ?? d.eqEnabled
            let bands = (try? c.decodeIfPresent([Band].self, forKey: .eqBands)) ?? nil
            eqBands = bands?.count == 5 ? bands! : d.eqBands
            bassEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .bassEnabled)) ?? d.bassEnabled
            bassAmount = Self.unit((try? c.decodeIfPresent(Float.self, forKey: .bassAmount)) ?? d.bassAmount)
            compressorEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .compressorEnabled)) ?? d.compressorEnabled
            compressorAmount = Self.unit((try? c.decodeIfPresent(Float.self, forKey: .compressorAmount)) ?? d.compressorAmount)
            nightMode = (try? c.decodeIfPresent(Bool.self, forKey: .nightMode)) ?? d.nightMode
        }

        private enum CodingKeys: String, CodingKey {
            case eqEnabled, eqBands, bassEnabled, bassAmount, compressorEnabled, compressorAmount, nightMode
        }

        private static func unit(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0 }

        var compressorThresholdDb: Float { -6 - 24 * compressorAmount }
        var compressorRatio: Float { 1.5 + 2.5 * compressorAmount }
        /// Makeup restores half of the gain reduction a 0 dB peak would get.
        var compressorMakeupDb: Float { -compressorThresholdDb * (1 - 1 / compressorRatio) * 0.5 }

        static let nightThresholdDb: Float = -30
        static let nightRatio: Float = 6
        static let nightMakeupDb: Float = 6
        /// Loudness curve added to the EQ while night mode is on.
        static let loudnessGainsDb: [Float] = [5, 1, -1, 1, 4]

        /// EQ gain per band as the kernel gets it: the user's, plus loudness in night mode.
        var effectiveEQGains: [Float] {
            (0..<5).map { i in
                let g = i < eqBands.count ? eqBands[i].gainDb : 0
                guard nightMode else { return g }
                return min(max(g + Self.loudnessGainsDb[i], -12), 12)
            }
        }

        var eqParams: DomineEQParams {
            var p = domine_eq_default_params()
            p.enabled = (eqEnabled || nightMode) ? 1 : 0
            let gains = effectiveEQGains
            withUnsafeMutableBytes(of: &p.bands) { raw in
                let bands = raw.bindMemory(to: DomineEQBand.self)
                for i in 0..<min(5, eqBands.count) {
                    bands[i] = DomineEQBand(freqHz: eqBands[i].freqHz, gainDb: gains[i], q: eqBands[i].q)
                }
            }
            return p
        }

        var bassParams: DomineBassParams {
            DomineBassParams(enabled: bassEnabled ? 1 : 0, amount: bassAmount, cutoffHz: 120)
        }

        var compressorParams: DomineCompressorParams {
            if nightMode {
                return DomineCompressorParams(enabled: 1, thresholdDb: Self.nightThresholdDb,
                                              ratio: Self.nightRatio, attackMs: 2, releaseMs: 100,
                                              makeupDb: Self.nightMakeupDb, limiterCeilingDb: -1)
            }
            return DomineCompressorParams(enabled: compressorEnabled ? 1 : 0, thresholdDb: compressorThresholdDb,
                                   ratio: compressorRatio, attackMs: 10, releaseMs: 100,
                                   makeupDb: compressorMakeupDb, limiterCeilingDb: -1)
        }
    }

    /// Effects for the pair. `left` and `right` are the speakers at Front Left
    /// and Front Right; while `linkSpeakers` is on, `left` drives both.
    struct EffectsSettings: Codable, Equatable, Sendable {
        var linkSpeakers = true
        var left = SideEffects()
        var right = SideEffects()

        init() {}
        init(both side: SideEffects) {
            left = side
            right = side
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            linkSpeakers = (try? c.decodeIfPresent(Bool.self, forKey: .linkSpeakers)) ?? true
            left = (try? c.decodeIfPresent(SideEffects.self, forKey: .left)) ?? SideEffects()
            right = (try? c.decodeIfPresent(SideEffects.self, forKey: .right)) ?? SideEffects()
        }

        private enum CodingKeys: String, CodingKey { case linkSpeakers, left, right }

        /// What the right speaker actually gets.
        var effectiveRight: SideEffects { linkSpeakers ? left : right }
        var nightMode: Bool { left.nightMode }
        func settingNightMode(_ on: Bool) -> EffectsSettings {
            var e = self
            e.left.nightMode = on
            e.right.nightMode = on
            return e
        }
        var swapped: EffectsSettings {
            var copy = self
            copy.left = right
            copy.right = left
            return copy
        }
    }

    enum Preset: String, CaseIterable, Sendable {
        case flat = "Flat"
        case bassBoost = "Bass Boost"
        case vocal = "Vocal"
        case loudness = "Loudness"
        case night = "Night"

        var settings: EffectsSettings {
            var s = SideEffects()
            func gains(_ g: [Float]) {
                s.eqEnabled = true
                for i in 0..<5 { s.eqBands[i].gainDb = g[i] }
            }
            switch self {
            case .flat: break
            case .bassBoost:
                gains([6, 2, 0, 0, 0])
                s.bassEnabled = true
                s.bassAmount = 0.5
            case .vocal: gains([-3, -2, 2, 3, 0])
            case .loudness: gains([5, 1, -1, 1, 4])
            case .night:
                gains([-4, 0, 0, 0, -2])
                s.compressorEnabled = true
                s.compressorAmount = 0.7
            }
            return EffectsSettings(both: s)
        }
    }
}
