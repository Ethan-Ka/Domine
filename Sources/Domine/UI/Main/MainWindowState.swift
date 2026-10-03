/// Everything the main window shows.
struct MainWindowState: Equatable, Sendable {
    /// Window subtitle under "Domine": one short phrase, e.g. "Playing in sync"
    /// or "Waiting for Front Right". `navigationSubtitle` takes a single
    /// string, so keep it to one phrase rather than joining pieces.
    var statusLine: String
    var isOn: Bool
    var mode: RoutingMode
    var isSurroundAvailable: Bool
    var canSwap: Bool
    /// Stereo: cards by position; positions missing here are drawn as
    /// placeholders. Surround: one card per speaker, each with `surround` set.
    var speakers: [SpeakerCardState]
    /// Master volume, 0...1.
    var masterVolume: Double
    /// Muted with the mute key. The slider keeps showing the volume.
    var isMuted: Bool
    /// The side whose test tone is playing, if any.
    var testToneSide: StereoSide?
    /// Tones need the engine running; Test L and Test R are disabled otherwise.
    var canPlayTestTones: Bool
    /// Surround controls, shown in Surround mode only.
    var surround: SurroundControls
    /// "Add Speaker…" is enabled while fewer than the maximum are placed.
    var canAddSurroundSpeaker: Bool
    /// The showcase demo (SPEC section 14).
    var demo: DemoState
    /// Shown at the bottom of the stage, e.g. while in mono fallback.
    var bannerMessage: String?
    var rooms: [Room] = []
    var currentRoomID: Room.ID?

    init(
        statusLine: String,
        isOn: Bool,
        mode: RoutingMode = .stereo,
        isSurroundAvailable: Bool = false,
        canSwap: Bool = true,
        speakers: [SpeakerCardState],
        masterVolume: Double,
        isMuted: Bool = false,
        testToneSide: StereoSide? = nil,
        canPlayTestTones: Bool = true,
        bannerMessage: String? = nil,
        surround: SurroundControls = SurroundControls(),
        canAddSurroundSpeaker: Bool = true,
        demo: DemoState = DemoState(),
        rooms: [Room] = [],
        currentRoomID: Room.ID? = nil
    ) {
        self.rooms = rooms
        self.currentRoomID = currentRoomID
        self.surround = surround
        self.canAddSurroundSpeaker = canAddSurroundSpeaker
        self.demo = demo
        self.statusLine = statusLine
        self.isOn = isOn
        self.mode = mode
        self.isSurroundAvailable = isSurroundAvailable
        self.canSwap = canSwap
        self.speakers = speakers
        self.masterVolume = masterVolume
        self.isMuted = isMuted
        self.testToneSide = testToneSide
        self.canPlayTestTones = canPlayTestTones
        self.bannerMessage = bannerMessage
    }

    func speaker(at position: SpeakerPosition) -> SpeakerCardState {
        speakers.first { $0.surround == nil && $0.position == position } ?? .placeholder(position)
    }

    /// The Surround cards, in the model's order.
    var surroundCards: [SpeakerCardState] {
        speakers.filter { $0.surround != nil }
    }

    var masterVolumePercent: Int {
        Int((min(max(masterVolume, 0), 1) * 100).rounded())
    }
}
