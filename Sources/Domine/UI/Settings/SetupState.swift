/// The Setup section of Settings > General: one status per first-run prompt.
struct SetupState: Equatable, Sendable {
    var captureStatus: AudioCaptureStatus = .unknown
    var isCheckingCapture = false
    var accessibilityGranted = false
    /// Still not granted after a trip to System Settings: the entry there is
    /// likely for another build of Domine.
    var accessibilityLikelyStale = false
    /// Output devices named "JBL Grip" that Core Audio lists now.
    var connectedGrips = 0
    /// The login item waits for approval in System Settings.
    var loginItemNeedsApproval = false
    /// The Domine virtual output driver is installed.
    var virtualOutputInstalled = false

    var virtualOutputText: String { virtualOutputInstalled ? "Installed" : "Not installed" }

    var captureText: String {
        if isCheckingCapture { return "Checking…" }
        return captureStatus == .working ? "Working" : "Not confirmed"
    }

    var accessibilityText: String {
        accessibilityGranted ? "Granted" : "Not granted"
    }

    /// One line under the Accessibility status while it is missing.
    var accessibilityNote: String? {
        if accessibilityGranted { return nil }
        return accessibilityLikelyStale
            ? "Remove Domine from the list, then drag this copy in."
            : "Switch on Domine in the list."
    }

    var speakersText: String {
        switch connectedGrips {
        case 0: "No JBL Grip connected"
        case 1: "1 JBL Grip connected"
        default: "\(connectedGrips) JBL Grips connected"
        }
    }
}
