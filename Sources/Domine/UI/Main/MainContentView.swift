import SwiftUI

/// The main window's content: window toolbar, stage, and bottom bar
/// (docs/mockups/Main.dc.html). Sheets are presented by the owner in
/// response to `selectSpeaker` and `openTuning`.
struct MainContentView: View {
    var state: MainWindowState
    var actions: MainWindowActions = .none

    var body: some View {
        VStack(spacing: 0) {
            StageView(state: state, onSelect: actions.selectSpeaker)
                .padding([.horizontal, .top], 12)
            MainBottomBar(state: state, actions: actions)
        }
        .navigationTitle("Domine")
        .navigationSubtitle(state.statusLine)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                RoomMenu(
                    rooms: state.rooms, currentRoomID: state.currentRoomID,
                    select: actions.selectRoom, save: actions.saveRoom, manage: actions.manageRooms)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                MainToolbarControls(state: state, actions: actions)
            }
        }
    }
}

#Preview("Playing") {
    MainContentView(state: SampleStates.playing)
        .frame(width: 640, height: 428)
}

#Preview("Mono fallback") {
    MainContentView(state: SampleStates.monoFallback)
        .frame(width: 640, height: 428)
}

#Preview("Playing, dark") {
    MainContentView(state: SampleStates.playing)
        .frame(width: 640, height: 428)
        .preferredColorScheme(.dark)
}

#Preview("Mono fallback, dark") {
    MainContentView(state: SampleStates.monoFallback)
        .frame(width: 640, height: 428)
        .preferredColorScheme(.dark)
}

#Preview("Off") {
    MainContentView(state: SampleStates.off)
        .frame(width: 640, height: 428)
}
