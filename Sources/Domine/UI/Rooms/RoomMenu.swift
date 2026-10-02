import SwiftUI

/// The Room popup: saved rooms, then Save Current Setup and Manage Rooms.
struct RoomMenu: View {
    var rooms: [Room]
    var currentRoomID: Room.ID?
    var select: @MainActor (Room.ID) -> Void = { _ in }
    var save: @MainActor () -> Void = {}
    var manage: @MainActor () -> Void = {}

    var body: some View {
        Menu {
            ForEach(rooms) { room in
                Toggle(room.name, isOn: Binding(
                    get: { room.id == currentRoomID },
                    set: { _ in select(room.id) }))
            }
            if !rooms.isEmpty { Divider() }
            Button("Save Current Setup…", action: save)
            Button("Manage Rooms…", action: manage)
                .disabled(rooms.isEmpty)
        } label: {
            Text(rooms.first { $0.id == currentRoomID }?.name ?? "Room")
        }
        .fixedSize()
        .help("Saved speaker setups")
        .accessibilityLabel("Room")
    }
}

#Preview {
    RoomMenu(rooms: [Room(name: "Living room", mode: .stereo)], currentRoomID: nil)
        .padding()
}
