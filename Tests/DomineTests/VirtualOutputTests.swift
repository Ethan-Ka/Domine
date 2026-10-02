import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Domine follows the virtual output's volume and mute (SPEC 3.3, 4a).
@MainActor
final class VirtualOutputTests {
    static let gripA = EngineTests.gripA
    static let gripB = EngineTests.gripB
    static let virtualUID = OutputRestorer.virtualOutputUID
    static let main = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)

    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let model: AppModel
    let system = FakeSystem()
    let tap = FakeVolumeKeyTap()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        model = AppModel(hal: hal, defaults: defaults, services: system.services)
        model.volumeKeyTap = tap
        var virtual = FakeHAL.Device(uid: Self.virtualUID, name: "Domine",
                                     transportType: kAudioDeviceTransportTypeVirtual)
        virtual.volumes = [Self.main: 0.2]
        virtual.mute = false
        hal.add(virtual)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        model.start()
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func route() async {
        hal.setDefault(uid: Self.gripA.uid)
        system.trusted = true
        model.generalSettings.volumeKeysEnabled = true
        await model.startRouting()
        #expect(model.engine.state == .running)
        #expect(hal.defaultOutputUID == Self.virtualUID)
    }

    private var virtualVolume: Float? { hal.volumes(uid: Self.virtualUID)[Self.main] }

    @Test func startSetsTheVirtualVolumeToTheMaster() async {
        await route()
        #expect(virtualVolume == model.pairSettings.masterVolume)
    }

    @Test func virtualVolumeMovesBothGrips() async {
        await route()
        hal.pressVolume(uid: Self.virtualUID, to: 0.75)
        #expect(model.pairSettings.masterVolume == 0.75)
        #expect(hal.volumes(uid: Self.gripA.uid) == [1: 0.75, 2: 0.75])
        #expect(hal.volumes(uid: Self.gripB.uid) == [1: 0.75, 2: 0.75])
    }

    @Test func virtualVolumeChangeIsNotEchoedBack() async {
        await route()
        hal.clearVolumeWrites()
        hal.pressVolume(uid: Self.virtualUID, to: 0.6)
        #expect(!hal.volumeWrites.contains { $0.uid == Self.virtualUID })
        #expect(virtualVolume == 0.6)
    }

    @Test func gripButtonWritesBackToTheVirtualDeviceOnce() async {
        await route()
        hal.clearVolumeWrites()
        hal.pressVolume(uid: Self.gripA.uid, to: 0.9)
        #expect(virtualVolume == 0.9)
        #expect(hal.volumeWrites.filter { $0.uid == Self.virtualUID }.count == 1)
        #expect(hal.volumes(uid: Self.gripB.uid) == [1: 0.9, 2: 0.9])
    }

    @Test func sliderUpdatesTheVirtualDevice() async {
        await route()
        model.setMasterVolume(0.35)
        #expect(virtualVolume == 0.35)
    }

    @Test func muteMirrorsBothWays() async {
        await route()
        hal.pressMute(uid: Self.virtualUID, to: true)
        #expect(model.isMuted)
        #expect(model.engine.muted)
        #expect(hal.muteWrites.isEmpty)
        model.setMuted(false)
        #expect(hal.muteWrites == [false])
        #expect(!model.isMuted)
    }

    @Test func keyTapIsNotStartedWithTheVirtualOutput() async {
        await route()
        #expect(!tap.isRunning)
        #expect(tap.startCount == 0)
    }

    @Test func keyTapStartsWithoutTheVirtualOutput() async {
        hal.remove(uid: Self.virtualUID)
        hal.add(.init(uid: "builtin", name: "Speakers", transportType: kAudioDeviceTransportTypeBuiltIn))
        hal.setDefault(uid: Self.gripA.uid)
        system.trusted = true
        model.generalSettings.volumeKeysEnabled = true
        await model.startRouting()
        #expect(tap.isRunning)
    }
}
