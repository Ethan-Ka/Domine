import Accelerate
import Foundation
import os

enum CalibrationResult: Equatable, Sendable {
    /// `levels` is nil when the analysis measured timing only.
    case success(offsetMs: Double, windows: Int, levels: ChirpLevels? = nil)
    case failure(reason: String)
}

/// Measures the arrival-time offset between two speakers from a microphone recording.
/// Speaker A plays the rising chirp, speaker B the falling chirp, once per period.
/// Window i covers recording samples [i * period, (i + 1) * period) in the recording's
/// own timeline, so both chirps of one repeat must land inside the same window.
///
/// Outliers: one window with a reflection or a misdetected peak must not fail
/// the run. Windows whose offset is within the tolerance of the median are
/// kept (1.5 ms or 3 x MAD, whichever is larger, capped at 3 ms); the run
/// succeeds when at least 3 windows and at least 60% of the detected windows
/// are kept, and reports the median of the kept windows.
///
/// It also measures how loud each speaker arrived: the height of its
/// matched-filter (correlation) peak. That height scales linearly with the
/// chirp's amplitude at the mic, counts only energy inside the chirp's band
/// and only the direct arrival, so steady room noise and later reflections
/// barely move it. The median over the kept windows is reported.
struct CalibrationAnalyzer {
    /// A window is accepted only if each correlation peak is at least this many times
    /// the median absolute correlation of that window. Noise alone gives about 6.
    static let minPeakToMedianRatio: Float = 10
    static let minAcceptedWindows = 3
    /// Outlier tolerance around the median offset, in ms.
    static let minToleranceMs = 1.5
    static let maxToleranceMs = 3.0
    static let madFactor = 3.0
    /// Share of the detected windows that must agree.
    static let minKeptFraction = 0.6
    /// Failure reasons when only one speaker's chirp was too weak to detect.
    static let weakRising = "Weak rising"
    static let weakFalling = "Weak falling"

    private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "Calibration")

    private struct Window {
        let offsetMs: Double
        let heightA: Double
        let heightB: Double
    }

    static func measure(recording: [Float], sampleRate: Double, rising: [Float], falling: [Float], period: Double = 1.0) -> CalibrationResult {
        let windowLen = Int(period * sampleRate)
        guard windowLen > 0, !rising.isEmpty, !falling.isEmpty, recording.count >= windowLen else {
            return .failure(reason: "Too noisy")
        }
        let corrA = correlate(recording, with: rising)
        let corrB = correlate(recording, with: falling)
        var windows: [Window] = []
        var strongA = 0, strongB = 0
        // Per-window details, logged only when the analysis fails.
        var details: [String] = []
        func logDetails() { for line in details { log.info("\(line, privacy: .public)") } }
        for w in 0..<(recording.count / windowLen) {
            let range = (w * windowLen)..<((w + 1) * windowLen)
            let a = peak(corrA, in: range), b = peak(corrB, in: range)
            if a.index != nil { strongA += 1 }
            if b.index != nil { strongB += 1 }
            guard let ia = a.index, let ib = b.index else {
                details.append("Window \(w): weak peak, ratios \(a.ratio) and \(b.ratio)")
                continue
            }
            let offset = (ib - ia) / sampleRate * 1000
            details.append("Window \(w): offset \(offset) ms, ratios \(a.ratio) and \(b.ratio)")
            windows.append(Window(offsetMs: offset, heightA: a.height, heightB: b.height))
        }
        guard windows.count >= minAcceptedWindows else {
            logDetails()
            log.info("Detected \(windows.count, privacy: .public) windows, too few; strong rising \(strongA, privacy: .public), falling \(strongB, privacy: .public)")
            // One speaker heard clearly and the other not: that one was too quiet.
            if strongA >= minAcceptedWindows, strongB < minAcceptedWindows { return .failure(reason: weakFalling) }
            if strongB >= minAcceptedWindows, strongA < minAcceptedWindows { return .failure(reason: weakRising) }
            return .failure(reason: "Too noisy")
        }
        let kept = consistent(windows)
        guard kept.count >= minAcceptedWindows,
              Double(kept.count) >= minKeptFraction * Double(windows.count) else {
            logDetails()
            log.info("Kept \(kept.count, privacy: .public) of \(windows.count, privacy: .public) windows, too few")
            return .failure(reason: "Inconsistent")
        }
        log.info("Kept \(kept.count, privacy: .public) of \(windows.count, privacy: .public) windows")
        let levels = ChirpLevels(rising: median(kept.map(\.heightA)), falling: median(kept.map(\.heightB)))
        return .success(offsetMs: median(kept.map(\.offsetMs)), windows: kept.count, levels: levels)
    }

    /// The windows within the tolerance of the median offset.
    private static func consistent(_ windows: [Window]) -> [Window] {
        let center = median(windows.map(\.offsetMs))
        let mad = median(windows.map { abs($0.offsetMs - center) })
        let tolerance = min(max(minToleranceMs, madFactor * mad), maxToleranceMs)
        return windows.filter { abs($0.offsetMs - center) <= tolerance }
    }

    /// Domine's delay convention: positive delays the right speaker (B).
    /// offset = arrival(B) - arrival(A); B early (negative) means delay B.
    static func delaySetting(forOffsetMs offset: Double) -> Int {
        Int((-offset).rounded())
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        guard n > 0 else { return 0 }
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// result[n] = sum_p signal[n + p] * template[p]; peak index is the template start.
    private static func correlate(_ signal: [Float], with template: [Float]) -> [Float] {
        let n = signal.count
        let padded = signal + [Float](repeating: 0, count: template.count - 1)
        var result = [Float](repeating: 0, count: n)
        vDSP_conv(padded, 1, template, 1, &result, 1, vDSP_Length(n), vDSP_Length(template.count))
        return result
    }

    /// Fractional peak index within range (nil if the peak is weak), the
    /// peak's height, and its peak-to-median ratio.
    private static func peak(_ corr: [Float], in range: Range<Int>) -> (index: Double?, height: Double, ratio: Double) {
        let slice = Array(corr[range])
        var maxVal: Float = 0
        var maxIdx: vDSP_Length = 0
        vDSP_maxvi(slice, 1, &maxVal, &maxIdx, vDSP_Length(slice.count))
        let mags = slice.map { abs($0) }.sorted()
        let median = mags[mags.count / 2]
        let ratio = median > 0 ? Double(maxVal / median) : 0
        guard maxVal > 0, median > 0, maxVal / median >= minPeakToMedianRatio else {
            return (nil, Double(maxVal), ratio)
        }
        let i = Int(maxIdx)
        var frac = 0.0
        if i > 0, i < slice.count - 1 {
            let y0 = Double(slice[i - 1]), y1 = Double(slice[i]), y2 = Double(slice[i + 1])
            let denom = y0 - 2 * y1 + y2
            if denom != 0 { frac = 0.5 * (y0 - y2) / denom }
        }
        return (Double(range.lowerBound + i) + frac, Double(maxVal), ratio)
    }
}
