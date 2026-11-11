import DomineDSP
import Foundation

extension PairSettings {
    /// One speaker's effects chain: EQ, bass enhancer, compressor.
    struct SideEffects: Codable, Equatable, Sendable {
        enum BandType: String, Codable, CaseIterable, Sendable {
            case peak, lowShelf, highShelf, notch

            var label: String {
                switch self {
                case .peak: "Peak"
                case .lowShelf: "Low shelf"
                case .highShelf: "High shelf"
                case .notch: "Notch"
                }
            }

            /// A notch cuts at its frequency and ignores gain.
            var usesGain: Bool { self != .notch }

            var kernelType: Int32 {
                switch self {
                case .peak: Int32(DOMINE_EQ_PEAKING.rawValue)
                case .lowShelf: Int32(DOMINE_EQ_LOW_SHELF.rawValue)
                case .highShelf: Int32(DOMINE_EQ_HIGH_SHELF.rawValue)
                case .notch: Int32(DOMINE_EQ_NOTCH.rawValue)
                }
            }

            /// Saved bands without a type: the first is a low shelf, the last a high shelf.
            static func fallback(index: Int, count: Int) -> BandType {
                guard count > 1 else { return .peak }
                if index == 0 { return .lowShelf }
                if index == count - 1 { return .highShelf }
                return .peak
            }
        }

        struct Band: Codable, Equatable, Sendable {
            var freqHz: Float
            var gainDb: Float
            var q: Float
            var type: BandType
            init(freqHz: Float, gainDb: Float = 0, q: Float = 1, type: BandType = .peak) {
                self.freqHz = freqHz
                self.gainDb = gainDb
                self.q = q
                self.type = type
            }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                func float(_ key: CodingKeys) -> Float? { (try? c.decodeIfPresent(Float.self, forKey: key)) ?? nil }
                self.init(freqHz: Self.clamp(float(.freqHz), SideEffects.freqRange, fallback: 1000),
                          gainDb: Self.clamp(float(.gainDb), SideEffects.gainRange, fallback: 0),
                          q: Self.clamp(float(.q), SideEffects.qRange, fallback: 1),
                          type: ((try? c.decodeIfPresent(BandType.self, forKey: .type)) ?? nil) ?? .peak)
            }
            private enum CodingKeys: String, CodingKey { case freqHz, gainDb, q, type }

            private static func clamp(_ v: Float?, _ r: ClosedRange<Float>, fallback: Float) -> Float {
                guard let v, v.isFinite else { return fallback }
                return min(max(v, r.lowerBound), r.upperBound)
            }
        }

        /// Only tells whether a saved band had a type.
        private struct TypeProbe: Decodable {
            var type: BandType?
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = (try? c.decodeIfPresent(BandType.self, forKey: .type)) ?? nil
            }
            private enum CodingKeys: String, CodingKey { case type }
        }

        static let maxBands = Int(DOMINE_EQ_BANDS)
        static let freqRange: ClosedRange<Float> = 20...20_000
        static let gainRange: ClosedRange<Float> = -12...12
        static let qRange: ClosedRange<Float> = 0.3...10

        static let defaultBands: [Band] = [
            Band(freqHz: 80, type: .lowShelf), Band(freqHz: 250), Band(freqHz: 1000), Band(freqHz: 4000),
            Band(freqHz: 10_000, type: .highShelf),
        ]

        var eqEnabled = false
        /// 1 to `maxBands` bands.
        var eqBands = SideEffects.defaultBands
        var bassEnabled = false
        /// 0...1.
        var bassAmount: Float = 0
        var compressorEnabled = false
        /// 0...1: threshold -6...-30 dB, ratio 1.5...4, automatic makeup.
        var compressorAmount: Float = 0
        /// Overrides the compressor and adds loudness without touching the settings above.
        var nightMode = false
        var nightStrength = NightStrength.medium

        init() {}

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = SideEffects()
            eqEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .eqEnabled)) ?? d.eqEnabled
            let bands = (try? c.decodeIfPresent([Band].self, forKey: .eqBands)) ?? nil
            if var bands, (1...Self.maxBands).contains(bands.count) {
                let probes = (try? c.decodeIfPresent([TypeProbe].self, forKey: .eqBands)) ?? nil
                for i in bands.indices where probes?[i].type == nil {
                    bands[i].type = BandType.fallback(index: i, count: bands.count)
                }
                eqBands = bands
            } else {
                eqBands = d.eqBands
            }
            bassEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .bassEnabled)) ?? d.bassEnabled
            bassAmount = Self.unit((try? c.decodeIfPresent(Float.self, forKey: .bassAmount)) ?? d.bassAmount)
            compressorEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .compressorEnabled)) ?? d.compressorEnabled
            compressorAmount = Self.unit((try? c.decodeIfPresent(Float.self, forKey: .compressorAmount)) ?? d.compressorAmount)
            nightMode = (try? c.decodeIfPresent(Bool.self, forKey: .nightMode)) ?? d.nightMode
            nightStrength = ((try? c.decodeIfPresent(NightStrength.self, forKey: .nightStrength)) ?? nil)
                ?? d.nightStrength
        }

        private enum CodingKeys: String, CodingKey {
            case eqEnabled, eqBands, bassEnabled, bassAmount, compressorEnabled, compressorAmount, nightMode
            case nightStrength
        }

        private static func unit(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0 }

        var compressorThresholdDb: Float { -6 - 24 * compressorAmount }
        var compressorRatio: Float { 1.5 + 2.5 * compressorAmount }
        /// Makeup restores half of the gain reduction a 0 dB peak would get.
        var compressorMakeupDb: Float { -compressorThresholdDb * (1 - 1 / compressorRatio) * 0.5 }

        static let nightThresholdDb: Float = NightStrength.medium.thresholdDb
        static let nightRatio: Float = NightStrength.medium.ratio
        static let nightMakeupDb: Float = NightStrength.medium.makeupDb
        /// Loudness curve added to the EQ while night mode is on, at the default band frequencies.
        static let loudnessGainsDb: [Float] = [5, 1, -1, 1, 4]
        private static let loudnessFreqs: [Float] = [80, 250, 1000, 4000, 10_000]

        /// The loudness curve at any frequency: exact at the default bands,
        /// linear in log frequency between them, flat beyond the ends.
        static func loudnessGainDb(atHz f: Float) -> Float {
            let fs = loudnessFreqs, gs = loudnessGainsDb
            if let i = fs.firstIndex(of: f) { return gs[i] }
            guard f > fs[0] else { return gs[0] }
            guard let hi = fs.firstIndex(where: { $0 > f }) else { return gs[gs.count - 1] }
            let t = (log10(f) - log10(fs[hi - 1])) / (log10(fs[hi]) - log10(fs[hi - 1]))
            return gs[hi - 1] + t * (gs[hi] - gs[hi - 1])
        }

        /// EQ gain per band as the kernel gets it: the user's, plus loudness in night mode.
        var effectiveEQGains: [Float] {
            eqBands.map { band in
                guard nightMode, band.type.usesGain else { return band.gainDb }
                return min(max(band.gainDb + Self.loudnessGainDb(atHz: band.freqHz), -12), 12)
            }
        }

        var eqParams: DomineEQParams {
            var p = domine_eq_default_params()
            p.enabled = (eqEnabled || nightMode) ? 1 : 0
            let count = min(Self.maxBands, eqBands.count)
            p.bandCount = Int32(count)
            let gains = effectiveEQGains
            withUnsafeMutableBytes(of: &p.bands) { raw in
                let bands = raw.bindMemory(to: DomineEQBand.self)
                for i in 0..<count {
                    bands[i] = DomineEQBand(freqHz: eqBands[i].freqHz, gainDb: gains[i], q: eqBands[i].q)
                }
            }
            withUnsafeMutableBytes(of: &p.types) { raw in
                let types = raw.bindMemory(to: Int32.self)
                for i in 0..<count { types[i] = eqBands[i].type.kernelType }
            }
            return p
        }

        var bassParams: DomineBassParams {
            DomineBassParams(enabled: bassEnabled ? 1 : 0, amount: bassAmount, cutoffHz: 120)
        }

        var compressorParams: DomineCompressorParams {
            if nightMode {
                return DomineCompressorParams(enabled: 1, thresholdDb: nightStrength.thresholdDb,
                                              ratio: nightStrength.ratio, attackMs: 2, releaseMs: 100,
                                              makeupDb: nightStrength.makeupDb, limiterCeilingDb: -1)
            }
            return DomineCompressorParams(enabled: compressorEnabled ? 1 : 0, thresholdDb: compressorThresholdDb,
                                   ratio: compressorRatio, attackMs: 10, releaseMs: 100,
                                   makeupDb: compressorMakeupDb, limiterCeilingDb: -1)
        }
    }

    /// How hard night mode compresses. Medium is the original fixed setting.
    enum NightStrength: String, Codable, CaseIterable, Sendable {
        case light, medium, strong

        var label: String {
            switch self {
            case .light: "Light"
            case .medium: "Medium"
            case .strong: "Strong"
            }
        }

        var thresholdDb: Float {
            switch self {
            case .light: -24
            case .medium: -30
            case .strong: -36
            }
        }

        var ratio: Float {
            switch self {
            case .light: 3
            case .medium: 6
            case .strong: 10
            }
        }

        var makeupDb: Float {
            switch self {
            case .light: 3
            case .medium: 6
            case .strong: 9
            }
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
        var nightStrength: NightStrength { left.nightStrength }
        func settingNightMode(_ on: Bool) -> EffectsSettings {
            var e = self
            e.left.nightMode = on
            e.right.nightMode = on
            return e
        }
        func settingNightStrength(_ strength: NightStrength) -> EffectsSettings {
            var e = self
            e.left.nightStrength = strength
            e.right.nightStrength = strength
            return e
        }
        var swapped: EffectsSettings {
            // Linked: `left` drives both speakers, so it must stay `left`.
            guard !linkSpeakers else { return self }
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
                for i in g.indices { s.eqBands[i].gainDb = g[i] }
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
