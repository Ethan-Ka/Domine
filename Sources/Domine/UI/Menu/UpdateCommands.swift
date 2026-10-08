import AppKit
import SwiftUI

/// About, "Check for Updates…" and "Uninstall Domine…" in the app menu.
struct UpdateCommands: Commands {
    let checker: UpdateChecker

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            // An empty build number: the standard panel would say "Version 0.2.1 (3)".
            Button("About Domine") {
                NSApp.orderFrontStandardAboutPanel(options: [.version: ""])
            }
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { checker.checkManually() }
            Button("Uninstall Domine…") { UninstallPrompt.run() }
        }
    }
}
