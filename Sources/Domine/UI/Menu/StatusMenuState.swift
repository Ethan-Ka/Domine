/// Everything the MenuBarExtra panel shows (SPEC 6a).
struct StatusMenuState: Equatable, Sendable {
    /// e.g. "Playing" or "Mono fallback".
    var statusText: String
    var isOn: Bool
    var mode: RoutingMode = .stereo
    /// The Surround segment of the mode picker is enabled.
    var isSurroundAvailable = false
    /// One row per speaker of the current mode: one in Single, two in Stereo,
    /// one per placed speaker in Surround.
    var speakers: [StatusMenuSpeaker]
    /// 0...maxVolume; above 1 is the boost.
    var masterVolume: Double
    var maxVolume: Double = 1
    var isMuted = false
    /// The preset the current sound settings match, if any.
    var preset: PairSettings.Preset? = .flat
    /// Auto-calibrate is offered only while routing.
    var isRouting = false
    /// Apps playing audio now.
    var apps: [StatusMenuApp] = []
    var rooms: [Room] = []
    var currentRoomID: Room.ID?

    /// Swap Left and Right exists only in Stereo.
    var canSwap: Bool { mode == .stereo }
}

/// One row of the menu's Apps section.
struct StatusMenuApp: Equatable, Sendable, Identifiable {
    var bundleID: String
    var name: String
    /// 0...1
    var volume: Double = 1
    /// Excluded from Domine, mode Always.
    var isExcluded = false
    var id: String { bundleID }
}
