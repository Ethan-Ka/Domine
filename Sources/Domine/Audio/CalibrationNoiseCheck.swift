import Accelerate
import Foundation

/// The background-noise check of auto-calibration (SPEC 12).
///
/// Before the chirps start the mic records the room with every speaker
/// silent. That noise is run through the same matched filters as the chirps,
/// so the noise floor (RMS of the filter output) is in the same band and the
/// same units as each speaker's level (its filter peak height). A speaker's
/// SNR is 20 log10(level / noise floor).
enum CalibrationNoiseCheck {
    /// Below 20 dB the noise is over 10% of the chirp peak: the level reading
    /// can be off by about 1 dB, and noise peaks start to rival the chirp
    /// peak (the detector needs a peak 10 times the median, about 17 dB over
    /// the RMS), so timing turns unreliable too.
    static let minSNRDb = 20.0
    /// When the loudest speaker clears the threshold by this much, a quiet
    /// speaker is to blame rather than the room.
    static let quietSpeakerMarginDb = 10.0

    enum Verdict: Equatable, Sendable {
        case ok
        /// The room is too loud for even the loudest speaker.
        case tooNoisy
        /// One speaker is far below the other; `rising` names which.
        case tooQuiet(rising: Bool)
    }

    /// RMS of the matched-filter output over the noise, averaged over both
    /// templates; nil when the noise is shorter than a template or silent.
    static func noiseFloor(_ noise: [Float], rising: [Float], falling: [Float]) -> Double? {
        let rms = [rising, falling].compactMap { filteredRMS(noise, template: $0) }
        guard rms.count == 2 else { return nil }
        let floor = (rms[0] + rms[1]) / 2
        return floor > 0 ? floor : nil
    }

    static func snrDb(level: Double, noiseFloor: Double) -> Double {
        20 * log10(level / noiseFloor)
    }

    static func verdict(levels: ChirpLevels, noiseFloor: Double) -> Verdict {
        let a = snrDb(level: levels.rising, noiseFloor: noiseFloor)
        let b = snrDb(level: levels.falling, noiseFloor: noiseFloor)
        guard a.isFinite, b.isFinite else { return .tooNoisy }
        guard min(a, b) < minSNRDb else { return .ok }
        if max(a, b) >= minSNRDb + quietSpeakerMarginDb { return .tooQuiet(rising: a < b) }
        return .tooNoisy
    }

    /// Only the outputs where the whole template overlaps the noise.
    private static func filteredRMS(_ noise: [Float], template: [Float]) -> Double? {
        guard !template.isEmpty, noise.count > template.count else { return nil }
        let n = noise.count - template.count + 1
        var out = [Float](repeating: 0, count: n)
        vDSP_conv(noise, 1, template, 1, &out, 1, vDSP_Length(n), vDSP_Length(template.count))
        var rms: Float = 0
        vDSP_rmsqv(out, 1, &rms, vDSP_Length(n))
        return Double(rms)
    }
}
