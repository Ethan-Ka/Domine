import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Single mode's own settings key, lossy rooms, and the volume link's
/// learned step across detach.
@MainActor
final class StoredSettingsTests {
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let system = FakeSystem()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit { UserDefaults().removePersistentDomain(forName: suiteName) }

    private func makeModel() -> AppModel {
        AppModel(hal: FakeHAL(), defaults: defaults, services: system.services)
    }

    // MARK: Single

    @Test func singleKeyIsPerSpeaker() {
        #expect(SettingsStore.singleStorageKey(uid: "A") == "Domine.single.A")
    }

    @Test func singleSavesUnderItsOwnKeyAndLeavesThePairAlone() {
        let model = makeModel()
        model.setSpeakers(left: "A", right: "B")
        model.setMasterVolume(0.8)
        model.setBalance(0.25)

        model.setRoutingMode(.single)
        #expect(model.pairSettings.masterVolume == 0.5)  // first use: defaults
        model.setMasterVolume(0.3)
        model.setSpeakerVolumeOffset(uid: "A", db: -3)
        var fx = PairSettings.EffectsSettings()
        fx.left.bassEnabled = true
        model.setEffects(fx)

        let pair = model.store.pairSettings(leftUID: "A", rightUID: "B")
        #expect(pair.masterVolume == 0.8)
        #expect(pair.balance == 0.25)
        #expect(pair.leftVolumeOffsetDb == 0)
        #expect(pair.effects == PairSettings.EffectsSettings())
        let single = model.store.singleSettings(uid: "A")
        #expect(single.masterVolume == 0.3)
        #expect(single.leftVolumeOffsetDb == -3)
        #expect(single.effects == fx)

        model.setRoutingMode(.stereo)
        #expect(model.pairSettings.masterVolume == 0.8)
        #expect(model.pairSettings.balance == 0.25)
        model.setRoutingMode(.single)
        #expect(model.pairSettings.masterVolume == 0.3)
        #expect(model.pairSettings.leftVolumeOffsetDb == -3)
    }

    @Test func singleSavesWithoutARightSpeaker() {
        let model = makeModel()
        model.setRoutingMode(.single)
        model.setSpeakers(left: "A", right: nil)
        model.setMasterVolume(0.6)
        #expect(model.store.singleSettings(uid: "A").masterVolume == 0.6)
        let again = makeModel()
        #expect(again.routingMode == .single)
        #expect(again.pairSettings.masterVolume == 0.6)
    }

    @Test func singleStoresOnlyItsOwnFields() {
        let model = makeModel()
        model.setRoutingMode(.single)
        model.setSpeakers(left: "A", right: "B")
        model.setBalance(0.5)
        model.setDelayMs(40)
        let single = model.store.singleSettings(uid: "A")
        #expect(single.balance == 0)
        #expect(single.delayMs == 0)
        #expect(model.store.pairSettings(leftUID: "A", rightUID: "B") == PairSettings())
    }

    // MARK: Rooms

    @Test func oneCorruptRoomDoesNotDropTheOthers() {
        let first = UUID(), second = UUID()
        let json = """
        [{"id":"\(first.uuidString)","name":"Patio","mode":"stereo","leftUID":"A","rightUID":"B"},
         {"id":"not a uuid","name":"Broken"},
         {"name":"No id"},
         {"id":"\(second.uuidString)","name":"Kitchen","mode":"single","leftUID":"C"}]
        """
        defaults.set(Data(json.utf8), forKey: "Domine.rooms")
        let rooms = SettingsStore(defaults: defaults).rooms
        #expect(rooms.map(\.id) == [first, second])
        #expect(rooms.map(\.name) == ["Patio", "Kitchen"])
        #expect(rooms[1].mode == .single)
    }

    @Test func roomsThatAreNotAListReadAsNone() {
        defaults.set(Data("{\"name\":\"x\"}".utf8), forKey: "Domine.rooms")
        #expect(SettingsStore(defaults: defaults).rooms.isEmpty)
    }

    // MARK: Volume link

    @Test func detachForgetsTheLearnedStep() {
        let hal = FakeHAL()
        var fine = EngineTests.gripA
        fine.volumeStep = 1.0 / 64
        let id = hal.add(fine)
        let link = SpeakerVolumeLink(hal: hal)
        link.attach([(fine.uid, id)])
        link.setAtOrAbove(0.3)
        #expect(link.step == 1.0 / 64)
        link.detach()
        #expect(link.step == nil)

        var coarse = EngineTests.gripB
        coarse.volumeStep = 1.0 / 8
        let coarseID = hal.add(coarse)
        link.attach([(coarse.uid, coarseID)])
        #expect(link.step == nil)
    }
}
