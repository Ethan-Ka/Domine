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

    var body: some Scene {
        Window("Domine", id: "main") {
            Group {
                if Self.isTestHost {
                    Color.clear
                } else {
                    MainView()
                        .environment(model)
                        .task { model.start() }
                }
            }
            .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 480)
        }
        .windowResizability(.contentSize)

        Settings {
            AppSettingsView()
                .environment(model)
        }
    }
}
