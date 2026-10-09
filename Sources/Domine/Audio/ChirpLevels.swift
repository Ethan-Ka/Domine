import Foundation

/// How loud each calibration chirp arrived at the microphone, as linear
/// matched-filter peak heights (SPEC 12.2). Only ratios between them mean
/// anything.
struct ChirpLevels: Equatable, Sendable {
    /// Speaker A, which plays the rising chirp.
    var rising: Double
    /// Speaker B, which plays the falling chirp.
    var falling: Double

    /// The quietest speaker's trim floor: -20 dB.
    static let minTrim = 0.1

    /// level(B) / level(A) in dB.
    var fallingOverRisingDb: Double { 20 * log10(falling / rising) }

    /// Trims that bring every speaker down to the quietest one:
    /// trim_i = quietest / level_i, so the quietest gets 1 and nothing is
    /// boosted, floored at -20 dB. Levels that are not finite and positive
    /// are left out of the result.
    static func trims(levels: [String: Double]) -> [String: Double] {
        let valid = levels.filter { $0.value.isFinite && $0.value > 0 }
        guard let quietest = valid.values.min() else { return [:] }
        return valid.mapValues { max(quietest / $0, minTrim) }
    }
}
