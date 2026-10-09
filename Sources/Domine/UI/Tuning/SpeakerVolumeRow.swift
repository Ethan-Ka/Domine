/// One speaker's hardware volume offset in Sync & Balance (SPEC 4a).
struct SpeakerVolumeRow: Identifiable, Equatable, Sendable {
    /// Device UID.
    var uid: String
    /// "Left", "Right", or a surround direction like "Front Left".
    var title: String
    /// Four characters from the UID that tell two "JBL Grip"s apart.
    var suffix: String?
    /// dB above or below the master volume, -12...12.
    var offsetDb: Double = 0
    /// Full hardware volume and still short of the offset.
    var isAtMaximum = false
    /// False when the Mac cannot set this speaker's volume; it can then only be cut.
    var hasHardwareVolume = true

    var id: String { uid }

    var label: String { [title, suffix].compactMap { $0 }.joined(separator: " ") }

    /// Positive offsets need hardware volume; a cut works on any speaker.
    var range: ClosedRange<Double> { -12...(hasHardwareVolume ? 12 : 0) }

    var readout: String {
        let db = Int(offsetDb.rounded())
        if db > 0 { return "+\(db) dB" }
        if db < 0 { return "\u{2212}\(-db) dB" }
        return "0 dB"
    }

    /// One short secondary line under the control, or nil.
    var note: String? {
        if !hasHardwareVolume { return "This speaker's volume can't be set from the Mac" }
        if isAtMaximum { return "At this speaker's maximum" }
        return nil
    }
}
