/// Everything the MenuBarExtra panel shows (SPEC 6a).
struct StatusMenuState: Equatable, Sendable {
    /// e.g. "Playing · Stereo · In sync" or "Left speaker off".
    var statusText: String
    var isOn: Bool
    var left: StatusMenuSpeaker
    var right: StatusMenuSpeaker
    /// 0...1
    var masterVolume: Double
}
