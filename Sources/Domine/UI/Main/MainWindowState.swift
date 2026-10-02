/// Everything the main window shows.
struct MainWindowState: Equatable, Sendable {
    /// Window subtitle under "Domine": one short phrase, e.g. "Playing in sync"
    /// or "Waiting for Front Right". `navigationSubtitle` takes a single
    /// string, so keep it to one phrase rather than joining pieces.
    var statusLine: String
    var isOn: Bool
    var mode: RoutingMode
    var isQuadAvailable: Bool
    var canSwap: Bool
    /// Cards by position. Positions missing here are drawn as placeholders.
    var speakers: [SpeakerCardState]
    /// Master volume, 0...1.
    var masterVolume: Double
    /// Muted with the mute key. The slider keeps showing the volume.
    var isMuted: Bool
    /// The side whose test tone is playing, if any.
    var testToneSide: StereoSide?
    /// Tones need the engine running; Test L and Test R are disabled otherwise.
    var canPlayTestTones: Bool
    /// Rear pair controls, shown in Quad mode only.
    var rearMode: RearMode
    /// Rear level, 0...1.
    var rearLevel: Double
    /// Shown at the bottom of the stage, e.g. while in mono fallback.
    var bannerMessage: String?

    init(
        statusLine: String,
        isOn: Bool,
        mode: RoutingMode = .stereo,
        isQuadAvailable: Bool = false,
        canSwap: Bool = true,
        speakers: [SpeakerCardState],
        masterVolume: Double,
        isMuted: Bool = false,
        testToneSide: StereoSide? = nil,
        canPlayTestTones: Bool = true,
        bannerMessage: String? = nil,
        rearMode: RearMode = .mirror,
        rearLevel: Double = 1
    ) {
        self.rearMode = rearMode
        self.rearLevel = rearLevel
        self.statusLine = statusLine
        self.isOn = isOn
        self.mode = mode
        self.isQuadAvailable = isQuadAvailable
        self.canSwap = canSwap
        self.speakers = speakers
        self.masterVolume = masterVolume
        self.isMuted = isMuted
        self.testToneSide = testToneSide
        self.canPlayTestTones = canPlayTestTones
        self.bannerMessage = bannerMessage
    }

    func speaker(at position: SpeakerPosition) -> SpeakerCardState {
        speakers.first { $0.position == position } ?? .placeholder(position)
    }

    var masterVolumePercent: Int {
        Int((min(max(masterVolume, 0), 1) * 100).rounded())
    }
}
