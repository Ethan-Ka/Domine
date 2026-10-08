import SwiftUI

/// Rename or delete saved rooms.
struct ManageRoomsSheet: View {
    var rooms: [Room]
    var rename: @MainActor (Room.ID, String) -> Void
    var delete: @MainActor (Room.ID) -> Void
    var importRooms: @MainActor ([Room]) -> Void
    var done: @MainActor () -> Void
    @State private var selection = Set<Room.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Rooms")
                .font(.headline)
            if rooms.isEmpty {
                Text("No saved rooms")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List(rooms, selection: $selection) { room in
                    ManageRoomRow(room: room, rename: rename, delete: delete)
                }
                .frame(height: min(CGFloat(rooms.count) * 32 + 8, 240))
            }
            HStack {
                Button("Export…") {
                    let chosen = selection.isEmpty ? rooms : rooms.filter { selection.contains($0.id) }
                    RoomsFilePanels.export(chosen)
                }
                .disabled(rooms.isEmpty)
                Button("Import…") {
                    if let imported = RoomsFilePanels.importRooms() { importRooms(imported) }
                }
                Spacer()
                Button("Done") { done() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(width: 360)
    }
}

private struct ManageRoomRow: View {
    var room: Room
    var rename: @MainActor (Room.ID, String) -> Void
    var delete: @MainActor (Room.ID) -> Void
    @State private var draft: String

    init(room: Room, rename: @escaping @MainActor (Room.ID, String) -> Void,
         delete: @escaping @MainActor (Room.ID) -> Void) {
        self.room = room
        self.rename = rename
        self.delete = delete
        _draft = State(initialValue: room.name)
    }

    var body: some View {
        HStack {
            TextField("Name", text: $draft)
                .labelsHidden()
                .onSubmit(commit)
            Button("Delete", role: .destructive) { delete(room.id) }
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = room.name
        } else if draft != room.name {
            rename(room.id, draft)
        }
    }
}

#Preview {
    ManageRoomsSheet(
        rooms: [Room(name: "Living room", mode: .stereo), Room(name: "Patio", mode: .surround)],
        rename: { _, _ in }, delete: { _ in }, importRooms: { _ in }, done: {})
}
