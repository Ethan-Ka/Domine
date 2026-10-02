import Foundation

/// One speaker in Surround mode (SPEC section 13): which output, and where it
/// sits around the listener. Azimuth in degrees, 0 straight ahead, positive to
/// the right (clockwise from above), wrapped to -180...180. Distance in metres
/// from the listener, 0.5...10. The stage view drags these; the engine turns
/// them into VBAP pans and distance delay and gain.
struct SurroundSpeaker: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Device UID (kAudioDevicePropertyDeviceUID). Never an AudioObjectID.
    var uid: String
    var azimuth: Float
    var distance: Float = 2

    var id: String { uid }

    static let maxCount = 16
    static let distanceRange: ClosedRange<Float> = 0.5...10

    /// Default azimuths for the nth speaker added (ITU-style ring first).
    static func defaultAzimuth(forIndex index: Int) -> Float {
        let ring: [Float] = [-30, 30, -110, 110, 0, 180, -70, 70, -150, 150, -50, 50, -90, 90, -130, 130]
        return ring[index % ring.count]
    }

    static func wrap(_ degrees: Float) -> Float {
        guard degrees.isFinite else { return 0 }
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}

extension SurroundSpeaker {
    private enum CodingKeys: String, CodingKey { case uid, azimuth, distance }

    /// A missing or mistyped azimuth or distance falls back to 0 and 2 m;
    /// values are wrapped and clamped. Only a missing UID fails.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decode(String.self, forKey: .uid)
        azimuth = Self.wrap((try? c.decodeIfPresent(Float.self, forKey: .azimuth)) ?? 0)
        let d = (try? c.decodeIfPresent(Float.self, forKey: .distance)) ?? 2
        distance = d.isFinite ? min(max(d, Self.distanceRange.lowerBound), Self.distanceRange.upperBound) : 2
    }
}
