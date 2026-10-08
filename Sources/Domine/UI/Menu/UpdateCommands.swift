import SwiftUI

/// "Check for Updates…" in the app menu, after About.
struct UpdateCommands: Commands {
    let checker: UpdateChecker

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { checker.checkManually() }
            Button("Uninstall Domine…") { UninstallPrompt.run() }
        }
    }
}
