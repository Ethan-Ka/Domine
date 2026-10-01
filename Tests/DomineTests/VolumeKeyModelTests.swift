import AppKit
import Foundation
import Testing
@testable import Domine

/// Records starts and stops instead of installing a system event tap.
@MainActor
final class FakeVolumeKeyTap: VolumeKeyTapping {
    private(set) var handler: VolumeKeyTap.Handler?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var isRunning: Bool { handler != nil }

    @discardableResult
    func start(handler: @escaping VolumeKeyTap.Handler) -> Bool {
        startCount += 1
        self.handler = handler
        return true
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func press(_ event: VolumeKeyEvent) {
        handler?(event)
    }
}

@MainActor
final class VolumeKeyModelTests {
    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let model: AppModel
    let system = FakeSystem()
    let tap = FakeVolumeKeyTap()
    var huds: [(Double, Bool)] = []

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        model = AppModel(hal: hal, defaults: defaults, services: system.services)
        model.volumeKeyTap = tap
        model.showVolumeHUD = { [weak self] volume, muted in self?.huds.append((volume, muted)) }
        hal.add(EngineTests.gripA)
        hal.add(EngineTests.gripB)
        model.start()
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func enableAndRun() async {
        system.trusted = true
        model.generalSettings.volumeKeysEnabled = true
        await model.startRouting()
        #expect(tap.isRunning)
    }

    static func event(_ key: VolumeKeyEvent.Key, step: Float = VolumeKeyEvent.normalStep) -> VolumeKeyEvent {
        VolumeKeyEvent(key: key, isKeyDown: true, isRepeat: false, step: step)
    }

    // MARK: Lifecycle

    @Test func tapIsOffByDefault() async {
        system.trusted = true
        await model.startRouting()
        #expect(model.engine.state == .running)
        #expect(!tap.isRunning)
        #expect(tap.startCount == 0)
    }

    @Test func tapNeedsAccessibility() async {
        model.generalSettings.volumeKeysEnabled = true
        await model.startRouting()
        #expect(!tap.isRunning)
        system.trusted = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(tap.isRunning)
    }

    @Test func tapNeedsTheEngineRunning() async {
        system.trusted = true
        model.generalSettings.volumeKeysEnabled = true
        #expect(!tap.isRunning)
        await model.startRouting()
        #expect(tap.isRunning)
        model.stopRouting()
        #expect(!tap.isRunning)
        #expect(tap.stopCount == 1)
    }

    @Test func turningTheSettingOffStopsTheTap() async {
        await enableAndRun()
        model.generalSettings.volumeKeysEnabled = false
        #expect(!tap.isRunning)
        #expect(!model.store.volumeKeysEnabled)
    }

    @Test func tapStartsOnlyOnce() async {
        await enableAndRun()
        model.updateVolumeKeyTap()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(tap.startCount == 1)
    }

    // MARK: Keys

    @Test func volumeUpRaisesMasterBySixteenth() async {
        await enableAndRun()
        model.setMasterVolume(0.5)
        tap.press(Self.event(.volumeUp))
        #expect(model.pairSettings.masterVolume == 0.5 + 1.0 / 16.0)
        #expect(model.mainWindowState.masterVolume == 0.5625)
        #expect(model.mainWindowState.masterVolumePercent == 56)
        let saved = model.store.pairSettings(leftUID: EngineTests.gripA.uid, rightUID: EngineTests.gripB.uid)
        #expect(saved.masterVolume == 0.5625)
        #expect(huds.count == 1)
        #expect(huds.last?.0 == 0.5625)
        #expect(huds.last?.1 == false)
    }

    @Test func volumeDownLowersMasterBySixteenth() async {
        await enableAndRun()
        model.setMasterVolume(0.5)
        tap.press(Self.event(.volumeDown))
        #expect(model.pairSettings.masterVolume == 0.4375)
    }

    @Test func fineStepIsSixtyFourth() async {
        await enableAndRun()
        model.setMasterVolume(0.5)
        let fine = VolumeKeyEvent.decode(
            subtype: 8, data1: VolumeKeyTests.data1(keyCode: 0, state: 0xA), flags: [.maskAlternate, .maskShift])
        #expect(fine != nil)
        if let fine { tap.press(fine) }
        #expect(model.pairSettings.masterVolume == 0.5 + 1.0 / 64.0)
    }

    @Test func clampsAtBothEnds() async {
        await enableAndRun()
        model.setMasterVolume(0.97)
        tap.press(Self.event(.volumeUp))
        #expect(model.pairSettings.masterVolume == 1)
        tap.press(Self.event(.volumeUp))
        #expect(model.pairSettings.masterVolume == 1)
        model.setMasterVolume(0.03)
        tap.press(Self.event(.volumeDown))
        #expect(model.pairSettings.masterVolume == 0)
        tap.press(Self.event(.volumeDown))
        #expect(model.pairSettings.masterVolume == 0)
        #expect(huds.count == 4)
    }

    @Test func muteTogglesModelAndEngine() async {
        await enableAndRun()
        model.setMasterVolume(0.5)
        tap.press(Self.event(.mute))
        #expect(model.isMuted)
        #expect(model.engine.muted)
        #expect(model.mainWindowState.isMuted)
        #expect(model.mainWindowState.masterVolume == 0.5)
        #expect(huds.last?.1 == true)
        tap.press(Self.event(.mute))
        #expect(!model.isMuted)
        #expect(!model.engine.muted)
    }

    @Test func volumeUpUnmutes() async {
        await enableAndRun()
        tap.press(Self.event(.mute))
        tap.press(Self.event(.volumeUp))
        #expect(!model.isMuted)
        #expect(!model.engine.muted)
    }

    @Test func sliderUnmutes() async {
        await enableAndRun()
        tap.press(Self.event(.mute))
        model.mainWindowActions.setMasterVolume(0.25)
        #expect(!model.isMuted)
        #expect(model.pairSettings.masterVolume == 0.25)
    }
}
