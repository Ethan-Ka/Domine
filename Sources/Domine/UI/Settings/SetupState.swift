/// The Setup section of Settings > General: one status per first-run prompt.
struct SetupState: Equatable, Sendable {
    var captureStatus: AudioCaptureStatus = .unknown
    var isCheckingCapture = false
    var accessibilityGranted = false
    /// Still not granted after a trip to System Settings: the entry there is
    /// likely for another build of Domine.
    var accessibilityLikelyStale = false
    /// Bluetooth speakers Core Audio lists now, of any brand.
    var connectedSpeakers = 0
    /// How many the current mode needs: 1 in Single, 2 in Stereo, the
    /// surround minimum in Surround.
    var speakersNeeded = 2

    var hasEnoughSpeakers: Bool { connectedSpeakers >= speakersNeeded }
    /// The login item waits for approval in System Settings.
    var loginItemNeedsApproval = false
    /// The Domine virtual output driver is installed.
    var virtualOutputInstalled = false

    var driverStatus: DriverStatus = .notInstalled
    /// The app carries a driver it can install.
    var canInstallDriver = false
    /// Install, Update or Remove is running.
    var driverActivity: DriverAction?
    /// Shown under the row after a failed or cancelled action.
    var driverFailure: String?

    var virtualOutputText: String {
        if let driverActivity { return driverActivity.progressText }
        switch driverStatus {
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        case .updateAvailable: return "Update available"
        }
    }

    /// The main button: Install or Update, nil when up to date or the app has no driver.
    var primaryDriverAction: DriverAction? {
        guard canInstallDriver else { return nil }
        switch driverStatus {
        case .notInstalled: return .install
        case .updateAvailable: return .update
        case .installed: return nil
        }
    }

    var showsRemoveDriver: Bool { driverStatus != .notInstalled }

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
        switch connectedSpeakers {
        case 0: "No speakers connected"
        case 1: "1 speaker connected"
        default: "\(connectedSpeakers) speakers connected"
        }
    }
}
