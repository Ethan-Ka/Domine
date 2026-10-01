import AppKit

/// Keeps Domine running with no window, so "Keep playing in the background"
/// keeps routing after the main window closes, and reopens the window when
/// the Dock icon is clicked or the app is launched again (SPEC 6a). Also
/// keeps the unit test host out of the user's way.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the main window's view. Reopening goes through the model so
    /// the app leaves background mode as the window comes back.
    static weak var model: AppModel?

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

    /// A Dock click, or launching Domine again from Finder. In background
    /// mode an open Settings window counts as visible, so the main window
    /// opens whenever the app is in the background.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let model = Self.model else { return true }
        if !hasVisibleWindows || model.isInBackground { model.showMainWindow() }
        return true
    }
}
