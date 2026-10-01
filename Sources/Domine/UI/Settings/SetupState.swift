/// The Setup section of Settings > General: one status per first-run prompt.
struct SetupState: Equatable, Sendable {
    var captureStatus: AudioCaptureStatus = .unknown
    var isCheckingCapture = false
    var accessibilityGranted = false
    /// Output devices named "JBL Grip" that Core Audio lists now.
    var connectedGrips = 0
    /// The login item waits for approval in System Settings.
    var loginItemNeedsApproval = false

    var captureText: String {
        if isCheckingCapture { return "Checking…" }
        return captureStatus == .working ? "Working" : "Not confirmed"
    }

    var accessibilityText: String {
        accessibilityGranted ? "Granted" : "Not granted"
    }

    var speakersText: String {
        switch connectedGrips {
        case 0: "No JBL Grip connected"
        case 1: "1 JBL Grip connected"
        default: "\(connectedGrips) JBL Grips connected"
        }
    }
}
