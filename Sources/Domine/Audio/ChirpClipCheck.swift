import Accelerate
import DomineDSP
import Foundation

/// How hot each speaker's chirp hit the microphone in one capture (SPEC 12,
/// test volume): the largest sample in that speaker's arrival windows, and
/// whether the mic clipped there.
struct ChirpPeaks: Equatable, Sendable {
    var rising: Float = 0
    var falling: Float = 0
    var risingClipped = false
    var fallingClipped = false

    var anyClipped: Bool { risingClipped || fallingClipped }
}

/// Finds clipped chirps in a capture. A flat-topped chirp wrecks the
/// correlation, so a clipped speaker is played again at a lower test volume.
enum ChirpClipCheck {
    /// Any sample at or over this is clipped.
    static let clipLevel: Float = 0.98
    /// This many samples in a row at or over `nearFullLevel` also count as
    /// clipped (a mic that limits just under full scale).
    static let nearFullRun = 3
    static let nearFullLevel: Float = 0.9
    /// When both speakers' arrival windows hold the same clipped samples,
    /// the louder one is blamed, or both when they are within this many dB.
    static let sameLevelDb: Float = 3

    /// Peaks of the chirp section of a capture. Each analysis window
    /// (one chirp period, aligned like `CalibrationController.analyzeAligned`)
    /// gives each speaker an arrival window: the template length from its
    /// correlation peak.
    static func peaks(recording: [Float], sampleRate: Double, rising: [Float], falling: [Float]) -> ChirpPeaks {
        let window = Int(sampleRate * DOMINE_CLICK_PERIOD_MS / 1000)
        let len = rising.count
        guard window > 0, len > 0, falling.count == len, recording.count >= window else { return ChirpPeaks() }
        let shift = CalibrationController.alignmentShift(recording: recording, sampleRate: sampleRate, rising: rising)
        let signal = Array(recording.dropFirst(shift))
        let clipped = clippedSamples(signal)
        let corrA = correlate(signal, with: rising)
        let corrB = correlate(signal, with: falling)
        var result = ChirpPeaks()
        var heightA: [Float] = [], heightB: [Float] = []
        for w in 0..<(signal.count / window) {
            let range = (w * window)..<((w + 1) * window)
            let (ia, ha) = argmax(corrA, in: range)
            let (ib, hb) = argmax(corrB, in: range)
            heightA.append(ha)
            heightB.append(hb)
            let spanA = ia..<min(ia + len, signal.count)
            let spanB = ib..<min(ib + len, signal.count)
            result.rising = max(result.rising, maxAbs(signal, in: spanA))
            result.falling = max(result.falling, maxAbs(signal, in: spanB))
            for i in clipped where spanA.contains(i) || spanB.contains(i) {
                let (a, b) = blame(inA: spanA.contains(i), inB: spanB.contains(i), heightA: ha, heightB: hb)
                if a { result.risingClipped = true }
                if b { result.fallingClipped = true }
            }
        }
        // Clipped somewhere, but in no arrival window (the peaks were too
        // mangled to find): blame the louder speaker.
        if !result.anyClipped, !clipped.isEmpty {
            let (a, b) = blame(inA: true, inB: true, heightA: median(heightA), heightB: median(heightB))
            result.risingClipped = a
            result.fallingClipped = b
        }
        return result
    }

    /// Indexes of clipped samples: at or over `clipLevel`, or inside a run
    /// of `nearFullRun` samples at or over `nearFullLevel`.
    static func clippedSamples(_ x: [Float]) -> [Int] {
        var out: [Int] = []
        var run = 0
        for (i, v) in x.enumerated() {
            let m = abs(v)
            run = m >= nearFullLevel ? run + 1 : 0
            if run == nearFullRun {
                for j in (i - nearFullRun + 1)...i where out.last.map({ $0 < j }) ?? true { out.append(j) }
            } else if m >= clipLevel || run > nearFullRun {
                out.append(i)
            }
        }
        return out
    }

    /// Which speaker a clipped sample belongs to.
    private static func blame(inA: Bool, inB: Bool, heightA: Float, heightB: Float) -> (Bool, Bool) {
        guard inA, inB else { return (inA, inB) }
        guard heightA > 0, heightB > 0 else { return (heightA >= heightB, heightB >= heightA) }
        let db = 20 * log10(heightA / heightB)
        if abs(db) <= sameLevelDb { return (true, true) }
        return (db > 0, db < 0)
    }

    private static func correlate(_ signal: [Float], with template: [Float]) -> [Float] {
        let n = signal.count
        let padded = signal + [Float](repeating: 0, count: template.count - 1)
        var result = [Float](repeating: 0, count: n)
        vDSP_conv(padded, 1, template, 1, &result, 1, vDSP_Length(n), vDSP_Length(template.count))
        return result
    }

    private static func argmax(_ x: [Float], in range: Range<Int>) -> (Int, Float) {
        var value: Float = 0
        var index: vDSP_Length = 0
        x.withUnsafeBufferPointer { buf in
            vDSP_maxvi(buf.baseAddress! + range.lowerBound, 1, &value, &index, vDSP_Length(range.count))
        }
        return (range.lowerBound + Int(index), value)
    }

    private static func maxAbs(_ x: [Float], in range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        var value: Float = 0
        x.withUnsafeBufferPointer { buf in
            vDSP_maxmgv(buf.baseAddress! + range.lowerBound, 1, &value, vDSP_Length(range.count))
        }
        return value
    }

    private static func median(_ x: [Float]) -> Float {
        let s = x.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }
}
