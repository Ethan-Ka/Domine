import SwiftUI

/// The menu bar panel in background mode, bound to `AppModel` (SPEC 6a).
struct BackgroundMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        StatusMenu(
            state: Binding(get: { model.statusMenuState }, set: { model.applyStatusMenuEdit($0) }),
            actions: actions)
            .onAppear {
                model.presentMainWindow = { [openWindow] in openWindow(id: "main") }
            }
    }

    private var actions: StatusMenuActions {
        var actions = model.statusMenuActions
        actions.openSettings = { [openSettings, model] in
            openSettings()
            model.services.activateApp()
        }
        return actions
    }
}
