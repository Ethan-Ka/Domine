import AppKit

/// Keeps Domine running with no window, so "Keep playing in the background"
/// keeps routing after the main window closes, and reopens the window when
/// the Dock icon is clicked (SPEC 6a). Also keeps the unit test host out of
/// the user's way.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opens the main window or brings it forward. Set by the main window's view.
    static var openMainWindow: (@MainActor () -> Void)?

    /// A prohibited app has no Dock icon and no menu bar, and it never
    /// activates, so the test host cannot take focus.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard DomineApp.isTestHost else { return }
        NSApp.setActivationPolicy(.prohibited)
    }

    /// Never quit on the last window: the app keeps routing with its window
    /// closed, and the test host's render windows close all the time.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.openMainWindow?() }
        return true
    }
}
