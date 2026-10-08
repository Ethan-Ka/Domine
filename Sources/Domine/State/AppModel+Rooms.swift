/// Rooms: named saved speaker setups.
extension AppModel {
    var currentRoom: Room? {
        currentRoomID.flatMap { id in rooms.first { $0.id == id } }
    }

    /// Saves the current mode and speakers under `name`, and makes it the
    /// current room. Returns nil for a blank name.
    @discardableResult
    func saveCurrentAsRoom(name: String) -> Room? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let room = Room(
            name: name, mode: routingMode, leftUID: leftUID, rightUID: rightUID,
            rearLeftUID: rearLeftUID, rearRightUID: rearRightUID,
            surroundUIDs: surroundSettings.uids.isEmpty ? nil : surroundSettings.uids)
        rooms.append(room)
        store.rooms = rooms
        setCurrentRoom(room.id)
        return room
    }

    /// Applies the room's mode and speakers, which restores their saved
    /// tuning. Speakers that are not connected show as "Not connected".
    /// Routing restarts once, and only if it was on.
    func selectRoom(_ id: Room.ID) {
        guard let room = rooms.first(where: { $0.id == id }) else { return }
        let wasActive = engine.state.isActive
        if wasActive { stopRouting() }
        setSpeakers(left: room.leftUID, right: room.rightUID)
        setRear(left: room.rearLeftUID, right: room.rearRightUID)
        if let surround = room.surroundUIDs, !surround.isEmpty { selectSurroundSet(surround) }
        setRoutingMode(room.mode)
        setCurrentRoom(id)
        if wasActive { Task { await startRouting() } }
    }

    func renameRoom(_ id: Room.ID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = rooms.firstIndex(where: { $0.id == id }) else { return }
        rooms[index].name = name
        store.rooms = rooms
    }

    func deleteRoom(_ id: Room.ID) {
        rooms.removeAll { $0.id == id }
        store.rooms = rooms
        if currentRoomID == id { setCurrentRoom(nil) }
    }

    /// Manual changes to speakers or mode leave the room it no longer matches.
    func refreshCurrentRoom() {
        guard let room = currentRoom else { return }
        let surroundMatches = room.mode != .surround || (room.surroundUIDs ?? []) == surroundSettings.uids
        let matches = room.mode == routingMode && room.leftUID == leftUID && room.rightUID == rightUID
            && room.rearLeftUID == rearLeftUID && room.rearRightUID == rearRightUID && surroundMatches
        if !matches { setCurrentRoom(nil) }
    }

    /// Adds rooms read from a file. Names that already exist get a number.
    func importRooms(_ imported: [Room]) {
        let added = RoomsFile.merge(imported, existingNames: rooms.map(\.name))
        guard !added.isEmpty else { return }
        rooms.append(contentsOf: added)
        store.rooms = rooms
    }

    private func setCurrentRoom(_ id: Room.ID?) {
        currentRoomID = id
        store.currentRoomID = id
    }
}
