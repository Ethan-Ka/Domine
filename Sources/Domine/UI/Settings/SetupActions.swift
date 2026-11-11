/// Buttons in the Setup section of Settings > General.
struct SetupActions {
    /// Reset the first-run flag and present the checklist on the main window.
    var showSetupAgain: @MainActor () -> Void = {}
    /// Run the audio capture probe, which triggers the system prompt.
    var requestCapture: @MainActor () -> Void = {}
    var openPrivacySettings: @MainActor () -> Void = {}
    var grantAccessibility: @MainActor () -> Void = {}
    /// Show the running Domine.app in Finder, to drag into the list.
    var revealApp: @MainActor () -> Void = {}
    /// Domine's own Bluetooth Speakers window.
    var openBluetoothSpeakers: @MainActor () -> Void = {}
    var openBluetoothSettings: @MainActor () -> Void = {}
    var openLoginItems: @MainActor () -> Void = {}
    var showInstallSteps: @MainActor () -> Void = {}
    /// Install, Update or Remove the driver, after the user confirmed it.
    var driver: @MainActor (DriverAction) -> Void = { _ in }
}
