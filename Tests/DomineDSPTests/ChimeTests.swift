import Foundation
import Testing
import DomineDSP

/// Swift reference of the chime formula in DomineChime.h.
enum ChimeReference {
    static func note(_ t: Double, _ hz: Double) -> Double {
        if t < 0 { return 0 }
        let attack = t < 0.008 ? t / 0.008 : 1.0
        let w = 2 * Double.pi * hz * t
        return attack * exp(-t / 0.25) * (sin(w) + 0.35 * sin(2 * w) + 0.12 * sin(3 * w))
    }

    static func sample(_ t: Double) -> Double {
        0.1914 * (note(t, 110) + note(t - 0.18, 165))
    }

    /// The engine tone: the chime repeating every 1.5 s.
    static func repeating(_ t: Double) -> Double {
        sample(t.truncatingRemainder(dividingBy: 1.5))
    }
}

struct ChimeTests {
    @Test func matchesSwiftReferenceWithin1e6() {
        var t = -0.01
        while t < 1.6 {
            #expect(abs(domine_chime_sample(t) - ChimeReference.sample(t)) < 1e-6)
            t += 0.00137
        }
    }

    @Test func silentBeforeStartAndStartsAtZero() {
        #expect(domine_chime_sample(-0.5) == 0)
        #expect(domine_chime_sample(0) == 0)
    }

    @Test func peakStaysAtOrBelowPointThreeAndReachesIt() {
        var peak = 0.0
        var t = 0.0
        while t < 1.5 {
            peak = max(peak, abs(domine_chime_sample(t)))
            t += 1.0 / 96_000
        }
        #expect(peak <= DOMINE_CHIME_PEAK)
        #expect(peak > 0.29)
    }

    @Test func secondNoteStartsAt180ms() {
        // Before 180 ms only note 1 sounds; the reference formula encodes that.
        #expect(abs(domine_chime_sample(0.1) - 0.1914 * ChimeReference.note(0.1, 110)) < 1e-9)
    }

    @Test func decaysTowardSilenceByTheEndOfThePattern() {
        var peak = 0.0
        var t = 1.3
        while t < 1.5 { peak = max(peak, abs(domine_chime_sample(t))); t += 0.0005 }
        #expect(peak < 0.01)
    }
}
