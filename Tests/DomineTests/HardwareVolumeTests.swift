import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Master volume as the speakers' linked hardware volume (SPEC 4a).
@MainActor
final class HardwareVolumeTests {
    static let gripA = EngineTests.gripA
    static let gripB = EngineTests.gripB

    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let model: AppModel
    let system = FakeSystem()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        model = AppModel(hal: hal, defaults: defaults, services: system.services)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    static func grip(_ base: FakeHAL.Device, volume: Float) -> FakeHAL.Device {
        var device = base
        device.volumes = [1: volume, 2: volume]
        return device
    }

    private func start(_ a: FakeHAL.Device, _ b: FakeHAL.Device) {
        hal.add(a)
        hal.add(b)
        model.start()
    }

    // MARK: Reading

    @Test func readsTheSpeakersVolumeWhenThePairIsSelected() {
        start(Self.grip(Self.gripA, volume: 0.3), Self.grip(Self.gripB, volume: 0.3))
        #expect(model.pairSettings.masterVolume == 0.3)
        #expect(model.mainWindowState.masterVolumePercent == 30)
        #expect(hal.volumeWrites.isEmpty)
    }

    @Test func differentVolumesLinkToTheLowerOne() {
        start(Self.grip(Self.gripA, volume: 0.47), Self.grip(Self.gripB, volume: 0.25))
        #expect(model.pairSettings.masterVolume == 0.25)
        #expect(hal.volumes(uid: Self.gripA.uid) == [1: 0.25, 2: 0.25])
        #expect(hal.volumes(uid: Self.gripB.uid) == [1: 0.25, 2: 0.25])
    }

    @Test func routingStartLinksVolumesThatDriftedApart() async {
        start(Self.grip(Self.gripA, volume: 0.5), Self.grip(Self.gripB, volume: 0.5))
        hal.pressVolume(uid: Self.gripA.uid, to: 0.2, notify: false)
        await model.startRouting()
        #expect(model.engine.state == .running)
        #expect(model.pairSettings.masterVolume == 0.2)
        #expect(hal.volumes(uid: Self.gripB.uid) == [1: 0.2, 2: 0.2])
    }

    // MARK: Writing

    @Test func masterWritesBothSpeakersOnEveryElement() {
        start(Self.gripA, Self.gripB)
        model.setMasterVolume(0.7)
        #expect(hal.volumeWrites == [
            .init(uid: Self.gripA.uid, element: 1, volume: 0.7),
            .init(uid: Self.gripA.uid, element: 2, volume: 0.7),
            .init(uid: Self.gripB.uid, element: 1, volume: 0.7),
            .init(uid: Self.gripB.uid, element: 2, volume: 0.7),
        ])
        #expect(model.engine.leftGain == 1)
        #expect(model.engine.rightGain == 1)
    }

    @Test func mainElementIsUsedWhenThereIsOne() {
        var a = Self.gripA
        a.volumes = [0: 0.5]
        start(a, Self.gripB)
        model.setMasterVolume(0.6)
        #expect(hal.volumes(uid: a.uid) == [0: 0.6])
        #expect(hal.volumeWrites.filter { $0.uid == a.uid } == [.init(uid: a.uid, element: 0, volume: 0.6)])
    }

    @Test func speakerWithoutVolumeGetsMasterAsKernelGain() {
        var b = Self.gripB
        b.volumes = [:]
        start(Self.gripA, b)
        model.setMasterVolume(0.4)
        #expect(hal.volumes(uid: Self.gripA.uid) == [1: 0.4, 2: 0.4])
        #expect(model.engine.leftGain == 1)
        #expect(model.engine.rightGain == 0.4)
    }

    @Test func balanceStaysAKernelGain() {
        start(Self.gripA, Self.gripB)
        model.setMasterVolume(0.6)
        model.setBalance(-0.25)
        #expect(model.engine.leftGain == 1)
        #expect(model.engine.rightGain == 0.75)
        #expect(hal.volumes(uid: Self.gripB.uid) == [1: 0.6, 2: 0.6])
    }

    // MARK: Stepped hardware volume

    @Test func betweenStepsUsesStepAboveAndKernelGainForTheRest() {
        var a = Self.grip(Self.gripA, volume: 0.5)
        var b = Self.grip(Self.gripB, volume: 0.5)
        a.volumeStep = 1.0 / 16
        b.volumeStep = 1.0 / 16
        start(a, b)
        model.setMasterVolume(0.7)
        #expect(hal.volumes(uid: a.uid) == [1: 0.75, 2: 0.75])
        #expect(hal.volumes(uid: b.uid) == [1: 0.75, 2: 0.75])
        #expect(model.pairSettings.masterVolume == 0.7)
        #expect(abs(model.engine.leftGain - 0.7 / 0.75) < 1e-6)
        #expect(abs(model.engine.rightGain - 0.7 / 0.75) < 1e-6)
        // Another value in the same step needs no hardware write.
        hal.clearVolumeWrites()
        model.setMasterVolume(0.72)
        #expect(hal.volumeWrites.isEmpty)
        #expect(abs(model.engine.leftGain - 0.72 / 0.75) < 1e-6)
        // On a step, gain is exactly unity.
        model.setMasterVolume(0.5)
        #expect(hal.volumes(uid: a.uid) == [1: 0.5, 2: 0.5])
        #expect(model.engine.leftGain == 1)
    }

    @Test func gripButtonBecomesTheMasterWithUnityKernelGain() {
        var a = Self.grip(Self.gripA, volume: 0.5)
        var b = Self.grip(Self.gripB, volume: 0.5)
        a.volumeStep = 1.0 / 16
        b.volumeStep = 1.0 / 16
        start(a, b)
        hal.pressVolume(uid: a.uid, to: 0.8125)
        #expect(model.pairSettings.masterVolume == 0.8125)
        #expect(model.engine.leftGain == 1)
        #expect(model.engine.rightGain == 1)
    }

    // MARK: External changes

    @Test func changeOnOneSpeakerIsCopiedToTheOther() {
        start(Self.gripA, Self.gripB)
        hal.clearVolumeWrites()
        hal.pressVolume(uid: Self.gripA.uid, to: 0.8)
        #expect(hal.volumes(uid: Self.gripB.uid) == [1: 0.8, 2: 0.8])
        #expect(model.pairSettings.masterVolume == 0.8)
        #expect(model.mainWindowState.masterVolumePercent == 80)
        // The echo of the write to B is suppressed, so nothing bounces back to A.
        #expect(hal.volumeWrites.allSatisfy { $0.uid == Self.gripB.uid })
        #expect(hal.volumeWrites.count == 2)
    }

    @Test func suppressionWindowIgnoresChangesRightAfterDomineWrote() {
        var clock = ContinuousClock.now
        let link = SpeakerVolumeLink(hal: hal, now: { clock })
        let idA = hal.add(Self.gripA)
        let idB = hal.add(Self.gripB)
        var reported: [Float] = []
        link.onExternalChange = { reported.append($0) }
        link.attach([(Self.gripA.uid, idA), (Self.gripB.uid, idB)])

        link.set(0.6)
        clock = clock.advanced(by: .milliseconds(100))
        hal.pressVolume(uid: Self.gripA.uid, to: 0.9)
        #expect(hal.volumes(uid: Self.gripB.uid) == [1: 0.6, 2: 0.6])
        #expect(reported.isEmpty)

        clock = clock.advanced(by: SpeakerVolumeLink.suppression)
        hal.pressVolume(uid: Self.gripA.uid, to: 0.9)
        #expect(hal.volumes(uid: Self.gripB.uid) == [1: 0.9, 2: 0.9])
        #expect(reported == [0.9])
    }

    @Test func reconnectedSpeakerIsLinkedAgain() {
        start(Self.gripA, Self.gripB)
        hal.remove(uid: Self.gripB.uid)
        model.syncWithCatalog()
        hal.add(Self.grip(Self.gripB, volume: 0.1))
        model.syncWithCatalog()
        #expect(model.pairSettings.masterVolume == 0.1)
        #expect(hal.volumes(uid: Self.gripA.uid) == [1: 0.1, 2: 0.1])
    }

    // MARK: Volume keys

    @Test func volumeKeysStepTheHardwareVolume() async {
        let tap = FakeVolumeKeyTap()
        model.volumeKeyTap = tap
        model.showVolumeHUD = { _, _ in }
        start(Self.gripA, Self.gripB)
        system.trusted = true
        model.generalSettings.volumeKeysEnabled = true
        await model.startRouting()
        #expect(tap.isRunning)
        tap.press(VolumeKeyModelTests.event(.volumeUp))
        #expect(hal.volumes(uid: Self.gripA.uid) == [1: 0.5625, 2: 0.5625])
        #expect(hal.volumes(uid: Self.gripB.uid) == [1: 0.5625, 2: 0.5625])
        tap.press(VolumeKeyModelTests.event(.volumeDown))
        tap.press(VolumeKeyModelTests.event(.volumeDown))
        #expect(hal.volumes(uid: Self.gripB.uid) == [1: 0.4375, 2: 0.4375])
    }
}
