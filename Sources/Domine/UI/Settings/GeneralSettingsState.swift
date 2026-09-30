/// Everything Settings > General shows. The view edits it through a binding.
struct GeneralSettingsState: Equatable, Sendable {
    enum CloseBehavior: String, CaseIterable, Sendable {
        case keepPlaying
        case stopPlaying

        var title: String {
            switch self {
            case .keepPlaying: "Keep playing in the background"
            case .stopPlaying: "Stop playing"
            }
        }
    }

    var volumeKeysEnabled = false
    var accessibilityGranted = false
    var restorePreviousOutput = true
    /// Display name of the output saved on start (SPEC 4c), if known.
    var previousOutputName: String?
    var closeBehavior: CloseBehavior = .keepPlaying
    var startWhenBothConnect = true
    var launchAtLogin = false
}
