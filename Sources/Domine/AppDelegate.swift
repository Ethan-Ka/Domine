import AppKit

/// Keeps the unit test host out of the user's way. A prohibited app has no
/// Dock icon and no menu bar, and it never activates, so it cannot take focus.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard DomineApp.isTestHost else { return }
        NSApp.setActivationPolicy(.prohibited)
    }

    /// The test host's own window is hidden, so closing a render test window
    /// closes the last visible one. That must not end the test run.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !DomineApp.isTestHost
    }
}
