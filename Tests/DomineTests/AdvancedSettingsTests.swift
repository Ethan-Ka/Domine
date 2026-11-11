import CoreAudio
import Foundation
import Testing
@testable import Domine

@MainActor
final class AdvancedSettingsTests {
    let hal = FakeHAL()
    let suiteName = "AdvancedSettingsTests." + UUID().uuidString
    let defaults: UserDefaults
    let system = FakeSystem()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    // MARK: Defaults and clamping

    @Test func defaultsAreTodaysValues() {
        let s = SettingsStore(defaults: defaults).advanced
        #expect(s == AdvancedSettings())
        #expect(s.keepAliveIdleSeconds == 2)
        #expect(s.keepAliveHz == 15)
        #expect(s.keepAliveLevelDb == -60)
        #expect(s.keepAliveAmplitude == 1.0e-3)
        #expect(s.clockSpeakerUID == nil)
        #expect(s.maxVolume == 2)
        #expect(s.offsetRangeDb == 12)
        #expect(s.calibrationRecordSeconds == 5.5)
        #expect(s.calibrationExtraAttempts == 3)
        #expect(s.calibrationStartVolume == 1)
        #expect(s.reconnectTiming == ReconnectTiming())
        #expect(s.showsVolumeHUD)
        #expect(s.volumeHUDSeconds == 1.5)
    }

    @Test func roundTrips() {
        let store = SettingsStore(defaults: defaults)
        var s = AdvancedSettings()
        s.keepAliveHz = 22
        s.clockSpeakerUID = "X"
        s.calibrationExtraAttempts = 5
        s.showsVolumeHUD = false
        store.advanced = s
        #expect(SettingsStore(defaults: defaults).advanced == s)
    }

    @Test func storedValuesClampOnRead() throws {
        let json = """
        {"keepAliveIdleSeconds": 0.1, "keepAliveHz": 99, "keepAliveLevelDb": -100, "maxVolume": 5,
         "offsetRangeDb": 7, "calibrationRecordSeconds": 1, "calibrationExtraAttempts": 9,
         "calibrationStartVolume": 0.1, "reconnectFirstDelaySeconds": 100, "reconnectRetrySeconds": 1,
         "reconnectGiveUpMinutes": 0, "volumeHUDSeconds": 10, "clockSpeakerUID": ""}
        """
        defaults.set(Data(json.utf8), forKey: "Domine.advanced")
        let s = SettingsStore(defaults: defaults).advanced
        #expect(s.keepAliveIdleSeconds == 0.5)
        #expect(s.keepAliveHz == 40)
        #expect(s.keepAliveLevelDb == -70)
        #expect(s.maxVolume == 2)
        #expect(s.offsetRangeDb == 6)
        #expect(s.calibrationRecordSeconds == 4)
        #expect(s.calibrationExtraAttempts == 5)
        #expect(s.calibrationStartVolume == 0.5)
        #expect(s.reconnectFirstDelaySeconds == 30)
        #expect(s.reconnectRetrySeconds == 10)
        #expect(s.reconnectGiveUpMinutes == 1)
        #expect(s.volumeHUDSeconds == 4)
        #expect(s.clockSpeakerUID == nil)
    }

    @Test func wrongTypesAndCorruptDataReadAsDefaults() {
        defaults.set(Data(#"{"keepAliveHz": "loud", "maxVolume": 1.5}"#.utf8), forKey: "Domine.advanced")
        var expected = AdvancedSettings()
        expected.maxVolume = 1.5
        #expect(SettingsStore(defaults: defaults).advanced == expected)
        defaults.set(Data("nope".utf8), forKey: "Domine.advanced")
        #expect(SettingsStore(defaults: defaults).advanced == AdvancedSettings())
    }

    // MARK: Model

    private func makeModel() -> AppModel {
        AppModel(hal: hal, defaults: defaults, services: system.services)
    }

    @Test func modelPushesSettingsAtLaunch() {
        var s = AdvancedSettings()
        s.keepAliveIdleSeconds = 4
        s.keepAliveHz = 20
        s.keepAliveLevelDb = -50
        s.calibrationRecordSeconds = 8
        s.calibrationExtraAttempts = 1
        s.calibrationStartVolume = 0.5
        s.reconnectFirstDelaySeconds = 2
        SettingsStore(defaults: defaults).advanced = s
        let model = makeModel()
        #expect(model.engine.keepAliveParams
            == KeepAliveParams(holdSeconds: 4, frequencyHz: 20, amplitude: pow(10, -50.0 / 20)))
        #expect(model.calibration.recordSeconds == 8)
        #expect(model.calibration.maxExtraAttempts == 1)
        #expect(model.calibration.startGain == 0.5)
        #expect(model.reconnector.timing.firstDelay == .seconds(2))
    }

    @Test func defaultKeepAliveParamsMatchTheKernel() {
        #expect(makeModel().engine.keepAliveParams == KeepAliveParams())
    }

    @Test func maximumVolumeCapsMasterAndBoost() {
        let model = makeModel()
        model.setMasterVolume(2)
        #expect(model.pairSettings.masterVolume == 2)
        model.advancedSettings.maxVolume = 1.5
        #expect(model.maxMasterVolume == 1.5)
        #expect(model.pairSettings.masterVolume == 1.5)
        #expect(model.engine.boost == PairSettings.boostGain(forMaster: 1.5))
        model.setMasterVolume(2)
        #expect(model.pairSettings.masterVolume == 1.5)
        #expect(model.store.advanced.maxVolume == 1.5)
    }

    @Test func offsetRangeLimitsOffsets() {
        hal.add(EngineTests.gripA)
        hal.add(EngineTests.gripB)
        let model = makeModel()
        model.start()
        let left = EngineTests.gripA.uid
        model.setSpeakerVolumeOffset(uid: left, db: -10)
        #expect(model.speakerVolumeOffsets[left] == -10)
        model.advancedSettings.offsetRangeDb = 6
        #expect(model.speakerVolumeOffsets[left] == -6)
        #expect(model.speakerVolumeRow(uid: left, title: "Left").range.lowerBound == -6)
        model.setSpeakerVolumeOffset(uid: left, db: -9)
        #expect(model.pairSettings.leftVolumeOffsetDb == -6)
        model.advancedSettings.offsetRangeDb = 12
        #expect(model.speakerVolumeOffsets[left] == -6)
    }

    @Test func restoreDefaultsResetsAndSaves() {
        let model = makeModel()
        model.advancedSettings.keepAliveHz = 30
        model.advancedSettings.showsVolumeHUD = false
        model.restoreAdvancedDefaults()
        #expect(model.advancedSettings == AdvancedSettings())
        #expect(model.store.advanced == AdvancedSettings())
        #expect(model.engine.keepAliveParams == KeepAliveParams())
    }

    @Test func clockChoicesNameTheConnectedSpeakers() {
        hal.add(EngineTests.gripA)
        hal.add(EngineTests.gripB)
        let model = makeModel()
        model.start()
        let choices = model.clockSpeakerChoices
        #expect(choices.map(\.uid) == [EngineTests.gripA.uid, EngineTests.gripB.uid])
        #expect(choices.allSatisfy { $0.name != "JBL Grip" && $0.isAvailable })
        model.advancedSettings.clockSpeakerUID = "AA-BB-CC-DD-EE-FF:output"
        #expect(model.clockSpeakerChoices.last?.isAvailable == false)
    }

    // MARK: Volume overlay

    @Test func overlayCanBeTurnedOff() {
        let model = makeModel()
        var shown = 0
        model.showVolumeHUD = { _, _ in shown += 1 }
        model.handleVolumeKey(VolumeKeyModelTests.event(.volumeUp))
        #expect(shown == 1)
        model.advancedSettings.showsVolumeHUD = false
        model.handleVolumeKey(VolumeKeyModelTests.event(.volumeUp))
        #expect(shown == 1)
    }
}
