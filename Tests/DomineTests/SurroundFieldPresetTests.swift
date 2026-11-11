import CoreAudio
import Foundation
import Testing
@testable import Domine

@MainActor
final class SurroundFieldPresetTests {
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let hal = FakeHAL()
    let system = FakeSystem()

    init() { defaults = UserDefaults(suiteName: suiteName)! }
    deinit { UserDefaults().removePersistentDomain(forName: suiteName) }

    private func makeModel() -> AppModel {
        for n in 1...3 { hal.add(SurroundModelTests.device(n)) }
        SettingsStore(defaults: defaults).startWhenBothConnect = false
        let model = AppModel(hal: hal, defaults: defaults, services: system.services)
        model.start()
        for n in 1...3 { model.addSurroundSpeaker(uid: SurroundModelTests.device(n).uid) }
        return model
    }

    @Test func applyingChangesOnlyTheFieldControls() {
        let model = makeModel()
        let uid = model.surroundSpeakers[0].uid
        model.setSurroundTrim(uid: uid, 0.5)
        model.setSurroundOffset(uid: uid, ms: 40)
        let before = model.surroundSettings
        model.applySurroundFieldPreset(.movie)
        var expected = before
        expected.width = 50
        expected.surroundLevel = 1.1
        expected.spatialAmount = 0.8
        expected.spatialRoomMs = 20
        #expect(model.surroundSettings == expected)
        #expect(model.currentSurroundPresetName == "Movie")
        model.applySurroundFieldPreset(.music)
        #expect(model.currentSurroundPresetName == "Music")
    }

    @Test func userPresetRoundTrips() {
        let model = makeModel()
        model.setSurroundWidth(70)
        model.setSurroundRotation(45)
        #expect(model.saveSurroundFieldPreset(name: "Music") == nil)
        #expect(model.saveSurroundFieldPreset(name: "  ") == nil)
        model.saveSurroundFieldPreset(name: "Party")
        #expect(SettingsStore(defaults: defaults).surroundFieldPresets.map(\.name) == ["Party"])
        model.applySurroundFieldPreset(.voice)
        model.applySurroundFieldPreset(model.surroundFieldPreset(named: "Party")!)
        #expect(model.surroundSettings.width == 70)
        #expect(model.surroundSettings.rotation == 45)
        model.renameSurroundFieldPreset("Party", to: "Loud")
        #expect(SettingsStore(defaults: defaults).surroundFieldPresets.map(\.name) == ["Loud"])
        model.deleteSurroundFieldPreset("Loud")
        #expect(SettingsStore(defaults: defaults).surroundFieldPresets.isEmpty)
    }

    @Test func lossyDecodeDropsBadEntries() {
        let json = #"[{"name":"A","width":500},{"width":3},{"name":"B"}]"#
        defaults.set(Data(json.utf8), forKey: "Domine.surroundFieldPresets")
        let presets = SettingsStore(defaults: defaults).surroundFieldPresets
        #expect(presets.map(\.name) == ["A", "B"])
        #expect(presets[0].width == 90)
        #expect(presets[1].surroundLevel == 0.7)
    }

    @Test func roomRemembersPresetName() {
        let model = makeModel()
        model.setRoutingMode(.surround)
        model.applySurroundFieldPreset(.movie)
        let room = model.saveCurrentAsRoom(name: "Den")
        #expect(room?.surroundPreset == "Movie")
        model.applySurroundFieldPreset(.voice)
        model.selectRoom(room!.id)
        #expect(model.surroundSettings.width == 50)
        let json = #"{"id":"\#(UUID().uuidString)","name":"X","mode":"stereo"}"#
        let old = try? JSONDecoder().decode(Room.self, from: Data(json.utf8))
        #expect(old?.surroundPreset == nil)
    }
}
