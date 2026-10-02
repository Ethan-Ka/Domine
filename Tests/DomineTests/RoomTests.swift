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
        assign(["A", "B", "C", "D"])
        model.setRoutingMode(.quad)
        let room = try #require(model.saveCurrentAsRoom(name: "  Patio "))
        #expect(room.name == "Patio")
        #expect(room.mode == .quad)
        #expect([room.leftUID, room.rightUID, room.rearLeftUID, room.rearRightUID] == ["A", "B", "C", "D"])
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
        model.setRoutingMode(.quad)
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

    @Test func rendersRoomViews() throws {
        let rooms = [Room(name: "Living room", mode: .stereo), Room(name: "Patio", mode: .quad)]
        try render(
            VStack(spacing: 20) {
                RoomMenu(rooms: rooms, currentRoomID: rooms[0].id)
                SaveRoomSheet(save: { _ in }, cancel: {})
                ManageRoomsSheet(rooms: rooms, rename: { _, _ in }, delete: { _ in }, done: {})
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
