import Foundation
import os

/// Keeps the recordings of the most recent failed calibration run in
/// ~/Library/Logs/Domine/Calibration for diagnosis, as 16-bit PCM mono WAV,
/// one file per pair. Successful runs save nothing. Called off the main
/// actor, never on the audio thread. Nothing is written under tests.
enum CalibrationRecordingArchive {
    struct Recording: Sendable {
        let label: String
        var samples: [Float]
        var sampleRate: Double
        /// This pair's own measurement failed.
        let failed: Bool

        var wavBytes: Int { 44 + samples.count * 2 }
    }

    /// The folder never holds more than this.
    static let maxBytes = 3 * 1024 * 1024
    static let reducedRate = 22_050.0

    private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "Calibration")

    static var directory: URL? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Domine/Calibration", isDirectory: true)
    }

    /// Deletes everything in the folder (a later run succeeded).
    static func clear() {
        guard let dir = directory else { return }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// What fits in `maxBytes`: every pair; else only the failed pairs;
    /// else those at 22.05 kHz; else as many of those as fit, latest first.
    static func fitting(_ recordings: [Recording]) -> [Recording] {
        func total(_ rs: [Recording]) -> Int { rs.reduce(0) { $0 + $1.wavBytes } }
        var rs = recordings
        if total(rs) <= maxBytes { return rs }
        rs = rs.filter(\.failed)
        if total(rs) <= maxBytes { return rs }
        rs = rs.map(downsampled)
        while total(rs) > maxBytes, !rs.isEmpty { rs.removeFirst() }
        return rs
    }

    /// Box-filtered resample to `reducedRate` (no-op at or below it).
    static func downsampled(_ r: Recording) -> Recording {
        guard r.sampleRate > reducedRate, !r.samples.isEmpty else { return r }
        let step = r.sampleRate / reducedRate
        let count = Int(Double(r.samples.count) / step)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let lo = Int(Double(i) * step), hi = min(max(Int(Double(i + 1) * step), lo + 1), r.samples.count)
            var sum: Float = 0
            for j in lo..<hi { sum += r.samples[j] }
            out[i] = sum / Float(hi - lo)
        }
        var copy = r
        copy.samples = out
        copy.sampleRate = reducedRate
        return copy
    }

    /// Deletes every earlier file, then writes what fits of this failed run.
    static func replace(with recordings: [Recording], date: Date = Date()) {
        guard let dir = directory, !recordings.isEmpty else { return }
        clear()
        let fm = FileManager.default
        let recordings = fitting(recordings)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for r in recordings {
                let url = dir.appendingPathComponent("calibration-\(stamp)-\(r.label).wav")
                try wav(r.samples, sampleRate: r.sampleRate).write(to: url, options: .atomic)
                log.info("Saved failed recording \(url.path, privacy: .public)")
            }
        } catch {
            log.error("Could not save recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// RIFF WAVE, format 1 (PCM), 1 channel, 16 bits, little endian.
    static func wav(_ samples: [Float], sampleRate: Double) -> Data {
        let rate = UInt32(max(sampleRate.rounded(), 1))
        let dataBytes = UInt32(samples.count * 2)
        var d = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for s in samples {
            let clamped = s.isFinite ? min(max(s, -1), 1) : 0
            u16(UInt16(bitPattern: Int16((clamped * 32767).rounded())))
        }
        return d
    }
}
