import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Domine

@MainActor
final class RoomTests {
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let model: AppModel

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        model = AppModel(hal: FakeHAL(), defaults: defaults, services: FakeSystem().services)
    }

    deinit { UserDefaults().removePersistentDomain(forName: suiteName) }

    private func assign(_ uids: [String]) {
        for (uid, position) in zip(uids, SpeakerPosition.allCases) {
            model.assign(uid, to: position)
        }
    }

    @Test func saveCapturesSetupAndMakesItCurrent() throws {
        assign(["A", "B"])
        model.setRoutingMode(.surround)
        for uid in ["A", "B", "C", "D"] { model.addSurroundSpeaker(uid: uid) }
        let room = try #require(model.saveCurrentAsRoom(name: "  Patio "))
        #expect(room.name == "Patio")
        #expect(room.mode == .surround)
        #expect([room.leftUID, room.rightUID] == ["A", "B"])
        #expect(room.surroundUIDs == ["A", "B", "C", "D"])
        #expect(model.rooms == [room])
        #expect(model.currentRoomID == room.id)
        #expect(model.saveCurrentAsRoom(name: "   ") == nil)
    }

    @Test func selectRestoresSpeakersModeAndSettings() throws {
        assign(["A", "B"])
        model.updatePairSettings { $0.delayMs = 12 }
        let first = try #require(model.saveCurrentAsRoom(name: "Desk"))
        assign(["C", "D"])
        model.updatePairSettings { $0.delayMs = 30 }
        model.setRoutingMode(.surround)
        #expect(model.currentRoomID == nil)

        model.selectRoom(first.id)
        #expect(model.leftUID == "A" && model.rightUID == "B")
        #expect(model.routingMode == .stereo)
        #expect(model.pairSettings.delayMs == 12)
        #expect(model.currentRoomID == first.id)
    }

    @Test func selectingRoomWithMissingSpeakersStillApplies() throws {
        assign(["gone-1", "gone-2"])
        let room = try #require(model.saveCurrentAsRoom(name: "Away"))
        assign(["A", "B"])
        model.selectRoom(room.id)
        #expect(model.leftUID == "gone-1")
        #expect(model.card(for: .frontLeft).connection == .disconnected)
    }

    @Test func manualChangeLeavesRoomAndRenameDeleteWork() throws {
        assign(["A", "B"])
        let room = try #require(model.saveCurrentAsRoom(name: "Desk"))
        model.assign("C", to: .frontLeft)
        #expect(model.currentRoomID == nil)

        model.renameRoom(room.id, to: "Office")
        model.renameRoom(room.id, to: "  ")
        #expect(model.rooms.first?.name == "Office")

        model.selectRoom(room.id)
        model.deleteRoom(room.id)
        #expect(model.rooms.isEmpty)
        #expect(model.currentRoomID == nil)
    }

    @Test func persistsAcrossModels() throws {
        assign(["A", "B"])
        let room = try #require(model.saveCurrentAsRoom(name: "Desk"))
        let again = AppModel(hal: FakeHAL(), defaults: defaults, services: FakeSystem().services)
        #expect(again.rooms == [room])
        #expect(again.currentRoomID == room.id)
        again.deleteRoom(room.id)
        let third = AppModel(hal: FakeHAL(), defaults: defaults, services: FakeSystem().services)
        #expect(third.rooms.isEmpty)
        #expect(third.currentRoomID == nil)
    }

    @Test func surroundRoomRestoresItsSet() throws {
        assign(["A", "B"])
        model.setRoutingMode(.surround)
        for uid in ["A", "B", "C"] { model.addSurroundSpeaker(uid: uid) }
        let room = try #require(model.saveCurrentAsRoom(name: "Den"))
        model.addSurroundSpeaker(uid: "D")
        #expect(model.currentRoomID == nil)
        model.selectRoom(room.id)
        #expect(model.surroundSpeakers.map(\.uid) == ["A", "B", "C"])
        #expect(model.routingMode == .surround)
        #expect(model.currentRoomID == room.id)
    }

    @Test func quadRoomDecodesAsSurround() throws {
        let json = #"[{"id":"6F2C1A52-58D6-4E43-9D8B-0E3E3E3B8A11","name":"Patio","mode":"quad","leftUID":"A","rightUID":"B","rearLeftUID":"C","rearRightUID":"D"}]"#
        let rooms = try JSONDecoder().decode([Room].self, from: Data(json.utf8))
        #expect(rooms.first?.mode == .surround)
        #expect(rooms.first?.surroundUIDs == ["A", "B", "C", "D"])
        let bad = #"[{"id":"6F2C1A52-58D6-4E43-9D8B-0E3E3E3B8A11","name":"X","mode":"nope"}]"#
        #expect(try JSONDecoder().decode([Room].self, from: Data(bad.utf8)).first?.mode == .stereo)
    }

    @Test func rendersRoomViews() throws {
        let rooms = [Room(name: "Living room", mode: .stereo), Room(name: "Patio", mode: .surround)]
        try render(
            VStack(spacing: 20) {
                RoomMenu(rooms: rooms, currentRoomID: rooms[0].id)
                SaveRoomSheet(save: { _ in }, cancel: {})
                ManageRoomsSheet(rooms: rooms, rename: { _, _ in }, delete: { _ in }, importRooms: { _ in }, done: {})
            }.padding(),
            named: "rooms")
    }

    private func render(_ view: some View, named name: String) throws {
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.background(.windowBackground))
            host.appearance = NSAppearance(named: appearance)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = OffscreenWindow(
                contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Domine-\(name)\(suffix).png")
            try data.write(to: url)
            #expect(host.fittingSize.width > 0)
        }
    }
}
