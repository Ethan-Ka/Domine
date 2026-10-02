import Accelerate
import Foundation

enum CalibrationResult: Equatable, Sendable {
    case success(offsetMs: Double, windows: Int)
    case failure(reason: String)
}

/// Measures the arrival-time offset between two speakers from a microphone recording.
/// Speaker A plays the rising chirp, speaker B the falling chirp, once per period.
/// Window i covers recording samples [i * period, (i + 1) * period) in the recording's
/// own timeline, so both chirps of one repeat must land inside the same window.
struct CalibrationAnalyzer {
    /// A window is accepted only if each correlation peak is at least this many times
    /// the median absolute correlation of that window. Noise alone gives about 6.
    static let minPeakToMedianRatio: Float = 10
    static let minAcceptedWindows = 3
    static let maxSpreadMs = 2.0

    static func measure(recording: [Float], sampleRate: Double, rising: [Float], falling: [Float], period: Double = 1.0) -> CalibrationResult {
        let windowLen = Int(period * sampleRate)
        guard windowLen > 0, !rising.isEmpty, !falling.isEmpty, recording.count >= windowLen else {
            return .failure(reason: "Too noisy")
        }
        let corrA = correlate(recording, with: rising)
        let corrB = correlate(recording, with: falling)
        var offsets: [Double] = []
        for w in 0..<(recording.count / windowLen) {
            let range = (w * windowLen)..<((w + 1) * windowLen)
            guard let a = peak(corrA, in: range), let b = peak(corrB, in: range) else { continue }
            offsets.append((b - a) / sampleRate * 1000)
        }
        guard offsets.count >= minAcceptedWindows else { return .failure(reason: "Too noisy") }
        let sorted = offsets.sorted()
        if sorted[sorted.count - 1] - sorted[0] > maxSpreadMs { return .failure(reason: "Inconsistent") }
        let n = sorted.count
        let median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        return .success(offsetMs: median, windows: n)
    }

    /// Domine's delay convention: positive delays the right speaker (B).
    /// offset = arrival(B) - arrival(A); B early (negative) means delay B.
    static func delaySetting(forOffsetMs offset: Double) -> Int {
        Int((-offset).rounded())
    }

    /// result[n] = sum_p signal[n + p] * template[p]; peak index is the template start.
    private static func correlate(_ signal: [Float], with template: [Float]) -> [Float] {
        let n = signal.count
        let padded = signal + [Float](repeating: 0, count: template.count - 1)
        var result = [Float](repeating: 0, count: n)
        vDSP_conv(padded, 1, template, 1, &result, 1, vDSP_Length(n), vDSP_Length(template.count))
        return result
    }

    /// Fractional peak index within range, or nil if the peak is weak.
    private static func peak(_ corr: [Float], in range: Range<Int>) -> Double? {
        let slice = Array(corr[range])
        var maxVal: Float = 0
        var maxIdx: vDSP_Length = 0
        vDSP_maxvi(slice, 1, &maxVal, &maxIdx, vDSP_Length(slice.count))
        let mags = slice.map { abs($0) }.sorted()
        let median = mags[mags.count / 2]
        guard maxVal > 0, median > 0, maxVal / median >= minPeakToMedianRatio else { return nil }
        let i = Int(maxIdx)
        var frac = 0.0
        if i > 0, i < slice.count - 1 {
            let y0 = Double(slice[i - 1]), y1 = Double(slice[i]), y2 = Double(slice[i + 1])
            let denom = y0 - 2 * y1 + y2
            if denom != 0 { frac = 0.5 * (y0 - y2) / denom }
        }
        return Double(range.lowerBound + i) + frac
    }
}
