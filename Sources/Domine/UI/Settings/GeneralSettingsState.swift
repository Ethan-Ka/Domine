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

        var caption: String {
            switch self {
            case .keepPlaying: "Audio keeps playing. Click Domine in the Dock to open the window again."
            case .stopPlaying: "Closing the window turns Domine off."
            }
        }
    }

    static let volumeKeysCaption = "Volume up, down, and mute change both speakers together while Domine is playing."
    static let accessibilityMissingCaption = "Domine does not have Accessibility access, so the keys still control the Mac. If Domine is already on in the Accessibility list, remove it and add it again."
    static let autoStartCaption = "Works even if the window is closed."

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
