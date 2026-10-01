import AppKit

/// Keeps Domine running with no window, so "Keep playing in the background"
/// keeps routing after the main window closes, and reopens the window when
/// the Dock icon is clicked (SPEC 6a).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opens the main window or brings it forward. Set by the main window's view.
    static var openMainWindow: (@MainActor () -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.openMainWindow?() }
        return true
    }
}
