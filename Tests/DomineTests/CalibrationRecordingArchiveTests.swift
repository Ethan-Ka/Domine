import Foundation
import Testing
@testable import Domine

/// The failed-run recordings stay under 3 MB (SPEC 12).
struct CalibrationRecordingArchiveTests {
    typealias Archive = CalibrationRecordingArchive

    static func pair(_ k: Int, failed: Bool, seconds: Double = 6, rate: Double = 48_000) -> Archive.Recording {
        Archive.Recording(label: "pair\(k)", samples: [Float](repeating: 0.1, count: Int(seconds * rate)),
                          sampleRate: rate, failed: failed)
    }

    @Test func smallRunIsKeptWhole() {
        let rs = (1...2).map { Self.pair($0, failed: $0 == 2) }
        #expect(Archive.fitting(rs).map(\.label) == ["pair1", "pair2"])
    }

    @Test func largeRunKeepsOnlyFailedPairs() {
        let rs = (1...8).map { Self.pair($0, failed: $0 == 8) }
        let kept = Archive.fitting(rs)
        #expect(kept.map(\.label) == ["pair8"])
        #expect(kept[0].sampleRate == 48_000)
    }

    @Test func stillTooLargeIsDownsampledAndCapped() {
        let rs = (1...16).map { Self.pair($0, failed: true) }
        let kept = Archive.fitting(rs)
        #expect(kept.allSatisfy { $0.sampleRate == Archive.reducedRate })
        #expect(kept.reduce(0) { $0 + $1.wavBytes } <= Archive.maxBytes)
        #expect(kept.last?.label == "pair16")
        #expect(abs((kept.first?.samples.first ?? 0) - 0.1) < 0.0001)
    }

    @Test func wavIs16BitPCM() {
        let data = Archive.wav([0, 1, -1], sampleRate: 22_050)
        #expect(data.count == 44 + 6)
        #expect(data[20] == 1 && data[34] == 16) // format PCM, 16 bits
        #expect(data[44] == 0 && data[46] == 0xFF && data[47] == 0x7F)
    }
}
