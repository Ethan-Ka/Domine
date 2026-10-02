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
            .sheet(isPresented: $model.showsSound) {
                SoundSheet(state: model.soundState, actions: model.soundActions)
            }
            .sheet(isPresented: $model.showsSaveRoom) {
                SaveRoomSheet(
                    save: { model.saveCurrentAsRoom(name: $0); model.showsSaveRoom = false },
                    cancel: { model.showsSaveRoom = false })
            }
            .sheet(isPresented: $model.showsManageRooms) {
                ManageRoomsSheet(
                    rooms: model.rooms,
                    rename: { model.renameRoom($0, to: $1) },
                    delete: { model.deleteRoom($0) },
                    done: { model.showsManageRooms = false })
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
