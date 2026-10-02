import SwiftUI

/// Hosts the main window content and its sheets, bound to `AppModel`.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        MainContentView(state: model.mainWindowState, actions: model.mainWindowActions)
            .sheet(item: $model.assignPosition) { position in
                AssignSheet(
                    state: model.assignSheetState(for: position),
                    actions: model.assignSheetActions(for: position))
            }
            .sheet(isPresented: $model.showsTuning) {
                TuningSheet(state: model.tuningState, actions: model.tuningActions)
            }
            .sheet(isPresented: $model.showsWelcome) {
                WelcomeView(state: model.welcomeState, actions: model.welcomeActions)
                    .interactiveDismissDisabled()
            }
            .onAppear {
                AppDelegate.model = model
                model.presentMainWindow = { [openWindow] in openWindow(id: "main") }
                model.leaveBackground()
            }
            .onDisappear { model.mainWindowDidClose() }
    }
}
