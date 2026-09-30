/// Everything one stage card shows. Plain data so the model can build it and
/// previews and tests can fake it. Each field is drawn as its own element;
/// nothing here is a preformatted joined string.
struct SpeakerCardState: Identifiable, Equatable, Sendable {
    var position: SpeakerPosition
    /// "L", "R", "L+R" in mono fallback, "RL" / "RR" in quad.
    var sideTag: String
    var deviceName: String?
    /// Four characters from the device UID that tell two "JBL Grip"s apart.
    var uidSuffix: String?
    /// Shown as "Volume 62%" when there is no `statusDetail`.
    var volumePercent: Int?
    /// e.g. "Connected", "Mono fallback", "Off or disconnected".
    var statusText: String
    /// Second status line, e.g. "Full mix" in mono fallback.
    var statusDetail: String?
    var connection: SpeakerConnection
    /// Post-kernel peak, 0...1 (SPEC section 3a).
    var level: Double
    var isMonoFallback: Bool

    var id: SpeakerPosition { position }

    init(
        position: SpeakerPosition,
        sideTag: String,
        deviceName: String? = nil,
        uidSuffix: String? = nil,
        volumePercent: Int? = nil,
        statusText: String,
        statusDetail: String? = nil,
        connection: SpeakerConnection,
        level: Double = 0,
        isMonoFallback: Bool = false
    ) {
        self.position = position
        self.sideTag = sideTag
        self.deviceName = deviceName
        self.uidSuffix = uidSuffix
        self.volumePercent = volumePercent
        self.statusText = statusText
        self.statusDetail = statusDetail
        self.connection = connection
        self.level = level
        self.isMonoFallback = isMonoFallback
    }

    /// The line under `statusText`: the detail if there is one, else the volume.
    var secondaryStatus: String? {
        if let statusDetail { return statusDetail }
        return volumePercent.map { "Volume \($0)%" }
    }

    /// A rear position in stereo mode.
    static func placeholder(_ position: SpeakerPosition) -> SpeakerCardState {
        SpeakerCardState(
            position: position,
            sideTag: "",
            statusText: "Planned for quad mode",
            connection: .placeholder)
    }
}
