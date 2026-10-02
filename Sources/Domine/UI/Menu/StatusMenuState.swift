/// Everything the MenuBarExtra panel shows (SPEC 6a).
struct StatusMenuState: Equatable, Sendable {
    /// e.g. "Playing" or "Left speaker off".
    var statusText: String
    var isOn: Bool
    var left: StatusMenuSpeaker
    var right: StatusMenuSpeaker
    /// 0...1
    var masterVolume: Double
    var isMuted = false
    /// The preset the current sound settings match, if any.
    var preset: PairSettings.Preset? = .flat
    /// Auto-calibrate is offered only while routing.
    var isRouting = false
    /// Apps playing audio now.
    var apps: [StatusMenuApp] = []
    var rooms: [Room] = []
    var currentRoomID: Room.ID?
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
