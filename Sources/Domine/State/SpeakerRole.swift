import DomineDSP

/// What part of the range a speaker plays (docs/IDEAS.md, customizability 1).
/// Full range is today's behaviour, bit for bit. A satellite is high-passed
/// at the crossover; a subwoofer plays the mono sum, low-passed at the
/// crossover, and in Surround is left out of panning.
enum SpeakerRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullRange
    case satellite
    case subwoofer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullRange: "Everything"
        case .satellite: "No deep bass"
        case .subwoofer: "Bass only"
        }
    }

    /// Crossover frequency range and default, shared by every speaker of a setup.
    static let crossoverRange: ClosedRange<Float> = 40...200
    static let defaultCrossoverHz: Float = 80

    static func clampCrossover(_ hz: Float) -> Float {
        hz.isFinite ? min(max(hz, crossoverRange.lowerBound), crossoverRange.upperBound) : defaultCrossoverHz
    }

    /// "80 Hz".
    static func crossoverReadout(_ hz: Double) -> String { "\(Int(hz.rounded())) Hz" }

    /// What the chosen roles do, in one line; nil while every speaker plays
    /// everything. Warns when the deep bass would play nowhere.
    static func caption(roles: [SpeakerRole], hz: Double) -> String? {
        let split = crossoverReadout(hz)
        let bassOnly = roles.filter { $0 == .subwoofer }.count
        let noBass = roles.contains(.satellite)
        let everything = roles.contains(.fullRange)
        if bassOnly == roles.count, !roles.isEmpty {
            return "Every speaker is bass only, so nothing plays above \(split)."
        }
        if bassOnly > 0 {
            let who = bassOnly == 1 ? "the bass-only speaker" : "the bass-only speakers"
            return "Sound below \(split) plays only on \(who)."
        }
        if noBass, !everything {
            return "No speaker plays the sound below \(split). Set one to Bass only or Everything."
        }
        if noBass {
            return "Speakers set to No deep bass skip the sound below \(split)."
        }
        return nil
    }

    /// Unknown stored values decode as full range.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SpeakerRole(rawValue: raw) ?? .fullRange
    }

    func crossoverParams(hz: Float) -> DomineCrossoverParams {
        let role: DomineSpeakerRole = switch self {
        case .fullRange: DOMINE_ROLE_FULL_RANGE
        case .satellite: DOMINE_ROLE_SATELLITE
        case .subwoofer: DOMINE_ROLE_SUBWOOFER
        }
        return DomineCrossoverParams(role: Int32(role.rawValue), freqHz: Self.clampCrossover(hz))
    }
}
