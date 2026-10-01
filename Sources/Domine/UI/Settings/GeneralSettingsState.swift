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

        /// Only where the title leaves something out.
        var caption: String? {
            switch self {
            case .keepPlaying: "Click Domine in the Dock to bring the window back."
            case .stopPlaying: nil
            }
        }
    }

    static let volumeKeysCaption = "Volume up, down, and mute change both speakers while Domine is playing."
    static let accessibilityMissingCaption = "Needs Accessibility access. Until then the keys change the Mac's own volume."
    static let autoStartCaption = "Works even if the window is closed."

    /// The volume keys are on but cannot be caught yet.
    var showsAccessibilityPrompt: Bool { volumeKeysEnabled && !accessibilityGranted }

    var restoreCaption: String {
        guard let previousOutputName else { return "Also happens on Quit." }
        return "Also happens on Quit. Previous output: \(previousOutputName)."
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
