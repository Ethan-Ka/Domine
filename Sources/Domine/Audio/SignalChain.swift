import Foundation

/// The sample rates along the routed path at start, and where (if anywhere)
/// a sample-rate conversion happens (SPEC section 4, Signal quality).
///
/// macOS mixes every app at the default output's rate, the tap delivers at
/// that rate, and the aggregate runs at Device A's rate. A tap or speaker at
/// another rate than the aggregate is converted by the aggregate's drift
/// compensation. Drift compensation also trims tiny clock differences at
/// matching rates; that is not counted as a conversion here.
struct SignalChain: Equatable, Sendable {
    struct Speaker: Equatable, Sendable {
        let label: String
        let uid: String
        /// nil when the read failed.
        let rate: Double?
    }

    /// The system default output the tap follows, when known.
    let sourceUID: String?
    let sourceRate: Double?
    let tapRate: Double
    let aggregateRate: Double
    let speakers: [Speaker]

    /// Each stage that converts the sample rate, in signal order.
    var conversions: [String] {
        var stages: [String] = []
        if let sourceRate, sourceRate != tapRate {
            stages.append("tap capture (default output \(Self.hz(sourceRate)), tap \(Self.hz(tapRate)))")
        }
        if tapRate != aggregateRate {
            stages.append("aggregate input (tap \(Self.hz(tapRate)) to \(Self.hz(aggregateRate)))")
        }
        for speaker in speakers {
            guard let rate = speaker.rate else {
                stages.append("Device \(speaker.label) (rate unknown)")
                continue
            }
            if rate != aggregateRate {
                stages.append("Device \(speaker.label) (\(Self.hz(aggregateRate)) to \(Self.hz(rate)))")
            }
        }
        return stages
    }

    var isConversionFree: Bool { conversions.isEmpty }

    /// One log line, for example: "default output BuiltInSpeakerDevice
    /// 44100 Hz, tap 44100 Hz, aggregate 44100 Hz, Device A <uid> 44100 Hz,
    /// Device B <uid> 44100 Hz: no sample-rate conversion".
    var summary: String {
        var parts: [String] = []
        let source = sourceRate.map(Self.hz) ?? "unknown rate"
        parts.append("default output \(sourceUID ?? "none") \(source)")
        parts.append("tap \(Self.hz(tapRate))")
        parts.append("aggregate \(Self.hz(aggregateRate))")
        for speaker in speakers {
            parts.append("Device \(speaker.label) \(speaker.uid) \(speaker.rate.map(Self.hz) ?? "unknown rate")")
        }
        let verdict = isConversionFree
            ? "no sample-rate conversion"
            : "SRC at " + conversions.joined(separator: "; ")
        return parts.joined(separator: ", ") + ": " + verdict
    }

    static func hz(_ rate: Double) -> String {
        rate == rate.rounded() && abs(rate) < 1e9 ? "\(Int(rate)) Hz" : String(format: "%.3f Hz", rate)
    }
}
