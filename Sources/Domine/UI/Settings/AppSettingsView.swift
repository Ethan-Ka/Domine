import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The `Settings` scene content, bound to `AppModel`.
struct AppSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsView(
            general: $model.generalSettings,
            exclusions: $model.exclusionsSettings,
            generalActions: model.generalSettingsActions,
            exclusionsActions: ExclusionsActions(chooseApp: chooseApp))
            .onAppear { model.refreshSystemStatus() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshSystemStatus()
            }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                model.addExclusion(bundleID: bundleID)
            }
        }
    }
}
