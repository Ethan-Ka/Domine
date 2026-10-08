/// Everything Settings > General shows. The view edits it through a binding.
struct GeneralSettingsState: Equatable, Sendable {
    enum CloseBehavior: String, CaseIterable, Sendable {
        case keepPlaying
        case stopPlaying
        case stopAndUseMacSpeakers

        var title: String {
            switch self {
            case .keepPlaying: "Keep playing in the background"
            case .stopPlaying: "Stop playing"
            case .stopAndUseMacSpeakers: "Stop and switch to the Mac's speakers"
            }
        }
    }

    static let accessibilityMissingCaption = "Needs Accessibility access."

    /// The volume keys are on but cannot be caught yet.
    var showsAccessibilityPrompt: Bool { volumeKeysEnabled && !accessibilityGranted }

    var restoreCaption: String? {
        previousOutputName.map { "Previous output: \($0)" }
    }

    var volumeKeysEnabled = false
    var accessibilityGranted = false
    var restorePreviousOutput = true
    /// Display name of the output saved on start (SPEC 4c), if known.
    var previousOutputName: String?
    var closeBehavior: CloseBehavior = .keepPlaying
    var startWhenBothConnect = true
    var launchAtLogin = false
    var reconnectDroppedSpeakers = true
    var keepSpeakersAwake = true
}
