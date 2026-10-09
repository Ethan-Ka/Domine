import Foundation

/// The calibration test volume of one pair (SPEC 12, test volume): the gain
/// on each chirp, 0...1, applied in the kernel to the chirp samples only.
struct ChirpGains: Equatable, Sendable {
    /// Speaker A, which plays the rising chirp.
    var rising: Double = 1
    /// Speaker B, which plays the falling chirp.
    var falling: Double = 1

    /// The first cut after a clipped capture, in dB.
    static let firstStepDb = -12.0
    /// Every later cut, and the step back up after a quiet capture, in dB.
    static let stepDb = 6.0
    /// The lowest test volume, in dB. A speaker that still clips here means
    /// the microphone is overloaded.
    static let floorDb = -30.0

    static func db(_ gain: Double) -> Double { 20 * log10(max(gain, 1e-6)) }
    static func gain(db: Double) -> Double { pow(10, db / 20) }

    /// The gain after a clipped capture at `gain`: 12 dB down from full,
    /// then 6 dB steps, never under the floor. Nil when `gain` is already at
    /// the floor.
    static func lowered(_ gain: Double) -> Double? {
        let now = db(gain)
        guard now > floorDb + 0.01 else { return nil }
        let next = now > -0.01 ? firstStepDb : now - stepDb
        return Self.gain(db: max(next, floorDb))
    }

    /// The gain after a too quiet capture at `gain`: 6 dB up, never over 1
    /// and never up to `clipped`, the highest gain that clipped. Nil when it
    /// cannot go up.
    static func raised(_ gain: Double, clipped: Double?) -> Double? {
        guard gain < 1 else { return nil }
        let next = min(Self.gain(db: db(gain) + stepDb), 1)
        if let clipped, next >= clipped - 1e-9 { return nil }
        return next
    }
}
