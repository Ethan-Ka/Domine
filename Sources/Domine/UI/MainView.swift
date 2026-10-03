import SwiftUI

/// Hosts the main window content and its sheets, bound to `AppModel`.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var surroundAssign = SurroundAssignPresenter()

    var body: some View {
        @Bindable var model = model
        @Bindable var surroundAssign = surroundAssign
        MainContentView(state: model.mainWindowState, actions: actions)
            .sheet(item: $model.assignPosition) { position in
                AssignSheet(
                    state: model.assignSheetState(for: position),
                    actions: model.assignSheetActions(for: position))
            }
            .sheet(item: $surroundAssign.target) { target in
                AssignSheet(
                    state: model.surroundAssignSheetState(for: target, selection: surroundAssign.selection),
                    actions: surroundAssignActions(for: target))
            }
            .sheet(isPresented: $model.showsTuning) {
                TuningSheet(state: model.tuningSheetState, actions: model.tuningSheetActions)
            }
            .sheet(isPresented: $model.showsSound) {
                SoundSheet(state: model.soundSheetState, actions: model.soundSheetActions)
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

    /// The model's actions plus the two that present the Surround sheet,
    /// whose state lives here.
    private var actions: MainWindowActions {
        var actions = model.mainWindowActions
        let presenter = surroundAssign
        actions.addSurroundSpeaker = { presenter.present(.add) }
        actions.chooseSurroundSpeaker = { presenter.present(.replace(uid: $0)) }
        return actions
    }

    private func surroundAssignActions(for target: SurroundAssignTarget) -> AssignSheetActions {
        let presenter = surroundAssign
        let appModel = model
        return AssignSheetActions(
            select: { presenter.selection = $0 },
            playTone: { appModel.playTestTone(surroundUID: $0) },
            cancel: { presenter.dismiss() },
            confirm: { uid in
                appModel.confirmSurroundAssign(uid, target: target)
                presenter.dismiss()
            })
    }
}
