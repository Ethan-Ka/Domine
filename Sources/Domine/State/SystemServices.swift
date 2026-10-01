import AppKit

/// System calls the model makes outside Core Audio: opening System Settings,
/// Accessibility trust, the login item, and app names. Tests pass fakes.
struct SystemServices: Sendable {
    var openURL: @MainActor @Sendable (URL) -> Void
    var isAccessibilityTrusted: @MainActor @Sendable () -> Bool
    var requestAccessibility: @MainActor @Sendable () -> Void
    var isLaunchAtLoginEnabled: @MainActor @Sendable () -> Bool
    var setLaunchAtLogin: @MainActor @Sendable (Bool) throws -> Void
    /// Display name of an installed app, or nil if it is not installed.
    var appName: @MainActor @Sendable (_ bundleID: String) -> String?
    /// The login item is registered but waits for approval in System Settings.
    var launchAtLoginRequiresApproval: @MainActor @Sendable () -> Bool = { false }
    var openLoginItemsSettings: @MainActor @Sendable () -> Void = {}
    /// Dock icon on (`.regular`) or off (`.accessory`) for background mode (SPEC 6a).
    var setActivationPolicy: @MainActor @Sendable (NSApplication.ActivationPolicy) -> Void = { _ in }
    /// Brings Domine's windows to the front.
    var activateApp: @MainActor @Sendable () -> Void = {}
    var terminateApp: @MainActor @Sendable () -> Void = {}

    static let bluetoothSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Bluetooth")!
    /// Privacy & Security > Screen & System Audio Recording. On macOS 15 and
    /// later its "System Audio Recording Only" list holds process-tap apps.
    /// Unverified on hardware: change it here if the pane does not open.
    static let audioCaptureSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static let live = SystemServices(
        openURL: { NSWorkspace.shared.open($0) },
        isAccessibilityTrusted: { VolumeKeyTap.isTrusted },
        requestAccessibility: { VolumeKeyTap.requestAccess() },
        isLaunchAtLoginEnabled: { LaunchAtLogin.isEnabled },
        setLaunchAtLogin: { try LaunchAtLogin.setEnabled($0) },
        appName: { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        },
        launchAtLoginRequiresApproval: { LaunchAtLogin.requiresApproval },
        openLoginItemsSettings: { LaunchAtLogin.openLoginItemsSettings() },
        setActivationPolicy: { _ = NSApp.setActivationPolicy($0) },
        activateApp: { NSApp.activate() },
        terminateApp: { NSApp.terminate(nil) })
}
