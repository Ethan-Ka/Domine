import Foundation

/// Peak meter ballistics (SPEC section 3a). Pure value type, no timing of its own.
///
/// The linear peak from the kernel is mapped to a display level in 0...1 on a
/// dBFS scale: `floorDB` (default -60 dBFS) maps to 0 and 0 dBFS maps to 1,
/// linear in dB between. Quiet music around -40 dBFS still lights segments.
///
/// Attack is instant: a level above the displayed one is shown immediately.
/// Release falls at a fixed `decayDBPerSecond` (default 20 dB/s). At the 30 Hz
/// poll rate that is about 0.67 dB per tick, so a full-scale burst takes 3 s to
/// fall to the floor and steps smoothly down through the 16 segments.
struct MeterBallistics: Sendable, Equatable {
    static let defaultDecayDBPerSecond: Double = 20
    static let defaultFloorDB: Double = -60

    let decayDBPerSecond: Double
    let floorDB: Double

    /// Currently displayed level, 0...1.
    private(set) var level: Float = 0

    init(decayDBPerSecond: Double = MeterBallistics.defaultDecayDBPerSecond,
         floorDB: Double = MeterBallistics.defaultFloorDB) {
        self.decayDBPerSecond = decayDBPerSecond
        self.floorDB = floorDB
    }

    /// Maps a linear peak to a display level in 0...1. NaN, negative, zero,
    /// and anything at or below the floor map to 0; 0 dBFS and above map to 1.
    static func displayLevel(peak: Float, floorDB: Double = MeterBallistics.defaultFloorDB) -> Float {
        guard peak > 0 else { return 0 } // also rejects NaN
        guard peak < 1 else { return 1 }
        let db = 20 * log10(Double(peak))
        let normalized = (db - floorDB) / -floorDB
        return Float(min(max(normalized, 0), 1))
    }

    /// Feeds one polled peak and returns the new displayed level, 0...1.
    /// `dt` is the time since the previous update; negative or NaN counts as 0.
    mutating func update(peak: Float, dt: TimeInterval) -> Float {
        let target = Self.displayLevel(peak: peak, floorDB: floorDB)
        if target >= level {
            level = target
        } else {
            let elapsed = dt.isNaN ? 0 : max(dt, 0)
            let drop = elapsed * decayDBPerSecond / -floorDB
            let decayed = Double(level) - drop
            level = Float(min(max(decayed, Double(target)), 1))
        }
        return level
    }

    /// Resets the displayed level to 0.
    mutating func reset() {
        level = 0
    }

    /// Number of lit segments for a display level: floor(level * count),
    /// clamped to 0...count. NaN counts as 0.
    static func litSegments(level: Float, count: Int = MeterBand.segmentCount) -> Int {
        guard count > 0, !level.isNaN else { return 0 }
        let clamped = min(max(level, 0), 1)
        return min(Int((clamped * Float(count)).rounded(.down)), count)
    }
}
