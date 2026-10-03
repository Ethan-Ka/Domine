import Foundation

/// Where a Surround card sits and which output it is. Plain data so the
/// model can build it and previews and tests can fake it.
struct SurroundCardInfo: Equatable, Sendable {
    /// Device UID (kAudioDevicePropertyDeviceUID).
    var uid: String
    /// Degrees, 0 straight ahead, positive to the right, -180...180.
    var azimuth: Double
    /// Metres from the listener, 0.5...10.
    var distance: Double

    /// Card title from the speaker's direction, e.g. "Front Left".
    var title: String { Self.title(forAzimuth: azimuth) }

    /// Side tag like "-30°".
    var angleTag: String { Self.angleTag(azimuth) }

    static func angleTag(_ azimuth: Double) -> String {
        "\(azimuth.isFinite ? Int(azimuth.rounded()) : 0)°"
    }

    static func title(forAzimuth azimuth: Double) -> String {
        let magnitude = abs(azimuth)
        let side = azimuth < 0 ? "Left" : "Right"
        switch magnitude {
        case ..<15: return "Center"
        case ..<60: return "Front \(side)"
        case ..<100: return "Side \(side)"
        case ..<165: return "Rear \(side)"
        default: return "Rear Center"
        }
    }

    /// Rounds to `step` degrees and wraps to -180...180.
    static func snapped(_ azimuth: Double, step: Double = 5) -> Double {
        Double(SurroundSpeaker.wrap(Float((azimuth / step).rounded() * step)))
    }
}
