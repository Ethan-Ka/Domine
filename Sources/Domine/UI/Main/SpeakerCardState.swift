/// Everything one stage card shows. Plain data so the model can build it and
/// previews and tests can fake it. Each field is drawn as its own element;
/// nothing here is a preformatted joined string.
struct SpeakerCardState: Identifiable, Equatable, Sendable {
    var position: SpeakerPosition
    /// "L", "R", "L+R" in mono fallback, an angle like "-30°" in Surround.
    var sideTag: String
    var deviceName: String?
    /// Four characters from the device UID that tell two "JBL Grip"s apart.
    var uidSuffix: String?
    /// e.g. "Connected", "Mono fallback", "Not connected".
    var statusText: String
    /// Optional second status line.
    var statusDetail: String?
    var connection: SpeakerConnection
    /// Post-kernel peak, 0...1 (SPEC section 3a).
    var level: Double
    var isMonoFallback: Bool
    /// Set for Surround cards: the output and where it sits. `position` is
    /// not used for these.
    var surround: SurroundCardInfo?

    var id: String { surround.map { "surround:" + $0.uid } ?? position.rawValue }

    /// "Front Left" for a Stereo card; for a Surround card, its direction.
    var title: String { surround?.title ?? position.title }

    init(
        position: SpeakerPosition,
        sideTag: String,
        deviceName: String? = nil,
        uidSuffix: String? = nil,
        statusText: String,
        statusDetail: String? = nil,
        connection: SpeakerConnection,
        level: Double = 0,
        isMonoFallback: Bool = false,
        surround: SurroundCardInfo? = nil
    ) {
        self.position = position
        self.sideTag = sideTag
        self.deviceName = deviceName
        self.uidSuffix = uidSuffix
        self.statusText = statusText
        self.statusDetail = statusDetail
        self.connection = connection
        self.level = level
        self.isMonoFallback = isMonoFallback
        self.surround = surround
    }

    /// A Surround card. The side tag is the speaker's angle.
    static func surroundCard(
        _ info: SurroundCardInfo,
        deviceName: String?,
        uidSuffix: String?,
        statusText: String,
        connection: SpeakerConnection,
        level: Double = 0
    ) -> SpeakerCardState {
        SpeakerCardState(
            position: .frontLeft, sideTag: info.angleTag,
            deviceName: deviceName, uidSuffix: uidSuffix,
            statusText: statusText, connection: connection, level: level,
            surround: info)
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
