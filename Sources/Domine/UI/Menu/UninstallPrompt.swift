import AppKit

/// The confirmation alert for "Uninstall Domine…" and the hand-off to the script.
@MainActor
enum UninstallPrompt {
    static func run() {
        let uninstaller = Uninstaller.live()
        guard uninstaller.scriptPath != nil else {
            let missing = NSAlert()
            missing.messageText = "The uninstaller is missing from this copy of Domine."
            missing.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Uninstall Domine?"
        alert.informativeText = "This removes Domine, its audio driver, and its settings. Audio stops for a few seconds while macOS restarts its sound system."
        let uninstall = alert.addButton(withTitle: "Uninstall")
        uninstall.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let keep = NSButton(checkboxWithTitle: "Keep my settings", target: nil, action: nil)
        keep.state = .off
        keep.sizeToFit()
        alert.accessoryView = keep
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        AppDelegate.model?.stopRouting()
        try? LaunchAtLogin.setEnabled(false)
        do {
            try uninstaller.run(keepSettings: keep.state == .on)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        NSApp.terminate(nil)
    }
}
