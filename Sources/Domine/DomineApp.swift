import Foundation
import SwiftUI

@main
struct DomineApp: App {
    /// True when the app only hosts the unit tests. The host then shows no
    /// sheets and never touches Core Audio, so tests run against the fake HAL alone.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var updater = Updater.live()

    var body: some Scene {
        Window("Domine", id: "main") {
            Group {
                if Self.isTestHost {
                    TestHostWindowHider()
                } else {
                    MainView()
                        .environment(model)
                        .task { model.start() }
                }
            }
            .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 480)
        }
        .windowResizability(.contentSize)
        .commands { UpdateCommands(updater: updater) }

        Window("Debug", id: "debug") {
            DebugView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)
        .commands { DebugCommand() }

        Settings {
            AppSettingsView()
                .environment(model)
                .environment(updater)
        }

        // Only in background mode, and never in the test host (SPEC 6a).
        MenuBarExtra("Domine", image: "MenuBarIcon", isInserted: menuBarItemInserted) {
            BackgroundMenu()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }

    /// If the user removes the item from the menu bar, the window comes back,
    /// so Domine is never left running with no way to reach it.
    private var menuBarItemInserted: Binding<Bool> {
        Binding(
            get: { !Self.isTestHost && model.isInBackground },
            set: { [model] inserted in
                if !inserted && model.isInBackground { model.showMainWindow() }
            })
    }
}

/// Debug menu item, Option-Command-D.
private struct DebugCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Debug") { openWindow(id: "debug") }
                .keyboardShortcut("d", modifiers: [.option, .command])
        }
    }
}
