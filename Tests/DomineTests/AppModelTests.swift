import AppKit
import CoreAudio
import Foundation
import Testing
@testable import Domine

@MainActor
final class AppModelTests {
    static let gripA = EngineTests.gripA
    static let gripB = EngineTests.gripB
    static let speakers = FakeHAL.Device(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                                         transportType: kAudioDeviceTransportTypeBuiltIn)

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

    private func addGripsAndStart() {
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        model.start()
    }

    private func newModel() -> AppModel {
        AppModel(hal: hal, defaults: defaults, services: system.services)
    }

    // MARK: Selection and persistence

    @Test func selectsTheTwoGripsByDefault() {
        addGripsAndStart()
        #expect(model.leftUID == Self.gripA.uid)
        #expect(model.rightUID == Self.gripB.uid)
        #expect(model.store.lastLeftUID == Self.gripA.uid)
        #expect(model.store.lastRightUID == Self.gripB.uid)
    }

    @Test func restoresLastUIDsOnLaunch() {
        let store = SettingsStore(defaults: defaults)
        store.lastLeftUID = Self.gripB.uid
        store.lastRightUID = Self.speakers.uid
        let model = newModel()
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        model.start()
        #expect(model.leftUID == Self.gripB.uid)
        #expect(model.rightUID == Self.speakers.uid)
    }

    @Test func terminationStopsTheEngine() async {
        addGripsAndStart()
        await model.startRouting()
        #expect(model.engine.state == .running)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(model.engine.state == .idle)
        #expect(hal.liveTapCount == 0)
        #expect(hal.liveAggregateCount == 0)
    }

    // MARK: Main window state

    @Test func statusLine() async {
        #expect(model.mainWindowState.statusLine == "Choose two speakers")
        addGripsAndStart()
        #expect(model.mainWindowState.statusLine == "Off")
        #expect(!model.mainWindowState.isOn)
        await model.startRouting()
        #expect(model.mainWindowState.statusLine == "Playing")
        #expect(model.mainWindowState.isOn)
        model.swapSides()
        #expect(model.mainWindowState.statusLine == "Playing, sides swapped")
        model.setRouting(false)
        #expect(model.mainWindowState.statusLine == "Off")
    }

    @Test func statusLineShowsWhyStartWasRefused() async {
        addGripsAndStart()
        hal.remove(uid: Self.gripB.uid)
        await model.startRouting()
        #expect(model.mainWindowState.statusLine == "Right speaker is not connected")
    }

    @Test func cardsFollowTheCatalog() {
        addGripsAndStart()
        let state = model.mainWindowState
        let left = state.speaker(at: .frontLeft)
        #expect(left.connection == .connected)
        #expect(left.deviceName == "JBL Grip")
        #expect(left.uidSuffix == "4F2A")
        #expect(left.sideTag == "L")
        #expect(left.volumePercent == 50)
        #expect(left.statusText == "Connected")
        #expect(state.speaker(at: .frontRight).uidSuffix == "9C11")
        #expect(state.speaker(at: .rearLeft).connection == .placeholder)
        #expect(state.speaker(at: .rearRight).connection == .placeholder)

        hal.remove(uid: Self.gripB.uid)
        let right = model.mainWindowState.speaker(at: .frontRight)
        #expect(right.connection == .disconnected)
        #expect(right.deviceName == "JBL Grip")
        #expect(right.uidSuffix == "9C11")
        #expect(right.volumePercent == nil)
    }

    @Test func unassignedCard() {
        hal.add(Self.gripA)
        model.start()
        #expect(model.leftUID == nil)
        #expect(model.mainWindowState.speaker(at: .frontLeft).connection == .unassigned)
    }

    @Test func swapFlipsSideTagsButNotDevices() async {
        addGripsAndStart()
        await model.startRouting()
        model.swapSides()
        let state = model.mainWindowState
        #expect(state.speaker(at: .frontLeft).sideTag == "R")
        #expect(state.speaker(at: .frontLeft).uidSuffix == "4F2A")
        #expect(state.speaker(at: .frontRight).sideTag == "L")
        #expect(model.engine.swapSides)
    }

    @Test func testToneTogglesOnPositionA() async {
        addGripsAndStart()
        await model.startRouting()
        model.toggleTestTone(.left)
        #expect(model.engine.testTone == .left)
        #expect(model.mainWindowState.testToneSide == .left)
        model.toggleTestTone(.left)
        #expect(model.engine.testTone == .off)
        #expect(model.mainWindowState.testToneSide == nil)
    }

    @Test func testTonesDisabledUntilRunning() async {
        addGripsAndStart()
        #expect(!model.mainWindowState.canPlayTestTones)
        await model.startRouting()
        #expect(model.mainWindowState.canPlayTestTones)
    }

    @Test func metersRunOnlyWhileRunning() async {
        addGripsAndStart()
        #expect(!model.meters.isRunning)
        await model.startRouting()
        #expect(model.meters.isRunning)
        model.setRouting(false)
        #expect(!model.meters.isRunning)
        #expect(model.engine.peaks() == (0, 0))
    }

    @Test func masterVolumeIsSavedAndScalesKernelGains() {
        addGripsAndStart()
        model.setMasterVolume(0.8)
        #expect(model.mainWindowState.masterVolumePercent == 80)
        #expect(model.engine.leftGain == 0.8)
        #expect(model.engine.rightGain == 0.8)
        #expect(model.store.pairSettings(leftUID: Self.gripA.uid, rightUID: Self.gripB.uid).masterVolume == 0.8)
    }

    // MARK: Assign

    @Test func assignPickingTheOtherSideSwaps() {
        addGripsAndStart()
        model.openAssign(.frontLeft)
        #expect(model.assignSelection == Self.gripA.uid)
        model.assignSheetActions(for: .frontLeft).confirm(Self.gripB.uid)
        #expect(model.leftUID == Self.gripB.uid)
        #expect(model.rightUID == Self.gripA.uid)
        #expect(model.assignPosition == nil)
        #expect(model.store.lastLeftUID == Self.gripB.uid)
        #expect(model.store.lastRightUID == Self.gripA.uid)
    }

    @Test func assignOtherDeviceKeepsTheOtherSide() {
        addGripsAndStart()
        model.assign(Self.speakers.uid, to: .frontRight)
        #expect(model.leftUID == Self.gripA.uid)
        #expect(model.rightUID == Self.speakers.uid)
    }

    @Test func assignRows() async {
        addGripsAndStart()
        model.openAssign(.frontLeft)
        var rows = model.assignSheetState(for: .frontLeft).rows
        #expect(rows.map(\.suffix) == [OutputDevice.suffix(forUID: Self.speakers.uid), "4F2A", "9C11"])
        #expect(rows[0].details == ["Built-in"])
        #expect(rows[1].details == ["Bluetooth"])
        #expect(rows[1].isSelected)
        #expect(rows[2].details == ["Bluetooth", "In use as Front Right"])
        #expect(rows.allSatisfy { !$0.canPlayTone })

        await model.startRouting()
        rows = model.assignSheetState(for: .frontLeft).rows
        #expect(rows.map(\.canPlayTone) == [false, true, true])
        model.playAssignTone(uid: Self.gripB.uid)
        #expect(model.engine.testTone == .right)
        model.playAssignTone(uid: Self.speakers.uid)
        #expect(model.engine.testTone == .right)
    }

    // MARK: Tuning

    @Test func tuningChangesPersistAndReachTheEngine() {
        addGripsAndStart()
        model.setDelayMs(12)
        model.setBalance(0.5)
        model.setMasterVolume(0.8)
        #expect(model.engine.delayMs == 12)
        #expect(abs(model.engine.leftGain - 0.4) < 1e-6)
        #expect(model.engine.rightGain == 0.8)
        let stored = model.store.pairSettings(leftUID: Self.gripA.uid, rightUID: Self.gripB.uid)
        #expect(stored == PairSettings(delayMs: 12, balance: 0.5, masterVolume: 0.8))
        #expect(model.tuningState.delayMs == 12)
        #expect(model.tuningState.balanceReadout == "Right 50%")

        // Swapping the pair flips the same physical tuning.
        model.assign(Self.gripB.uid, to: .frontLeft)
        #expect(model.engine.delayMs == -12)
        #expect(model.engine.leftGain == 0.8)
        #expect(abs(model.engine.rightGain - 0.4) < 1e-6)

        // A fresh model loads it back.
        let reloaded = newModel()
        #expect(reloaded.pairSettings == PairSettings(delayMs: -12, balance: -0.5, masterVolume: 0.8))
        #expect(reloaded.engine.delayMs == -12)
    }

    @Test func delayClampsToTheRange() {
        addGripsAndStart()
        model.setDelayMs(120)
        #expect(model.engine.delayMs == 50)
        model.setExtendedRange(true)
        model.setDelayMs(-120)
        #expect(model.engine.delayMs == -120)
        model.setExtendedRange(false)
        #expect(model.engine.delayMs == -50)
    }

    @Test func resetKeepsMasterVolume() {
        addGripsAndStart()
        model.setMasterVolume(0.7)
        model.setDelayMs(8)
        model.setBalance(-0.3)
        model.tuningActions.reset()
        #expect(model.pairSettings == PairSettings(masterVolume: 0.7))
        #expect(model.engine.delayMs == 0)
    }

    @Test func reportedLatencies() {
        var a = FakeHAL.Device(uid: Self.gripA.uid, name: "JBL Grip")
        a.latency = DeviceLatency(deviceFrames: 8000, safetyOffsetFrames: 336, streamFrames: 400)
        var b = FakeHAL.Device(uid: Self.gripB.uid, name: "JBL Grip")
        b.latency = DeviceLatency(deviceFrames: 8000, safetyOffsetFrames: 48, streamFrames: 400)
        hal.add(a)
        hal.add(b)
        model.start()
        model.openTuning()
        #expect(model.showsTuning)
        #expect(model.tuningState.reportedLatencies == "Reported latency: left 182 ms, right 176 ms")
        #expect(!model.tuningState.isClickTestAvailable)
    }

    @Test func clickTestStartsOnTheLeft() async {
        addGripsAndStart()
        await model.startRouting()
        #expect(model.tuningState.isClickTestAvailable)
        model.tuningActions.playClickTest()
        #expect(model.engine.testTone == .left)
        model.cancelTone()
        #expect(model.engine.testTone == .off)
    }

    // MARK: Settings

    @Test func generalSettingsReadAndWriteTheStore() {
        let general = model.generalSettings
        #expect(!general.startWhenBothConnect)  // the store default wins over the view's
        #expect(general.restorePreviousOutput)
        #expect(general.closeBehavior == .keepPlaying)
        #expect(!general.accessibilityGranted)

        model.generalSettings.closeBehavior = .stopPlaying
        model.generalSettings.volumeKeysEnabled = true
        model.generalSettings.startWhenBothConnect = true
        model.generalSettings.restorePreviousOutput = false
        #expect(model.store.closeBehavior == .stopPlaying)
        #expect(model.store.volumeKeysEnabled)
        #expect(model.store.startWhenBothConnect)
        #expect(!model.store.restorePreviousOutput)
        #expect(newModel().generalSettings.closeBehavior == .stopPlaying)
    }

    @Test func launchAtLoginAndAccessibility() {
        model.generalSettings.launchAtLogin = true
        #expect(system.launchAtLogin)
        system.failLaunchAtLogin = true
        model.generalSettings.launchAtLogin = false
        #expect(model.generalSettings.launchAtLogin)  // reverted to the real state

        system.trusted = true
        model.refreshSystemStatus()
        #expect(model.generalSettings.accessibilityGranted)
        model.generalSettingsActions.grantAccessibility()
        #expect(system.accessRequests == 1)
    }

    @Test func exclusionsAreStored() {
        addGripsAndStart()
        #expect(model.exclusionsSettings.outputChoices.map(\.label)
            == ["MacBook Pro Speakers (\(OutputDevice.suffix(forUID: Self.speakers.uid)))", "JBL Grip (4F2A)", "JBL Grip (9C11)"])
        model.addExclusion(bundleID: "us.zoom.xos")
        #expect(model.exclusionsSettings.items.first?.appName == "zoom.us")
        model.exclusionsSettings.items[0].mode = .onlyDuringCalls
        model.exclusionsSettings.playThroughDeviceUID = Self.speakers.uid
        #expect(model.store.exclusions == [AppExclusion(bundleID: "us.zoom.xos", mode: .onlyDuringCalls)])
        #expect(model.store.excludedAppsPlayThroughUID == Self.speakers.uid)
        let reloaded = newModel()
        #expect(reloaded.exclusionsSettings.items
            == [ExclusionItem(bundleID: "us.zoom.xos", appName: "zoom.us", mode: .onlyDuringCalls)])
    }

    // MARK: Welcome

    @Test func welcomeShowsUntilContinue() {
        #expect(model.showsWelcome)
        model.welcomeActions.continueSetup()
        #expect(!model.showsWelcome)
        #expect(model.store.hasCompletedWelcome)
        #expect(!newModel().showsWelcome)
    }

    @Test func welcomeSteps() async {
        hal.add(Self.gripA)
        model.start()
        #expect(model.welcomeState.steps.allSatisfy { !$0.isDone })
        hal.add(Self.gripB)
        model.syncWithCatalog()
        #expect(model.welcomeState.isDone(.unpairJBL))
        #expect(model.welcomeState.isDone(.connectSpeakers))
        #expect(!model.welcomeState.isDone(.allowCapture))
        model.captureAccess.markWorking()
        #expect(model.welcomeState.allDone)

        model.welcomeActions.perform(.connectSpeakers)
        model.welcomeActions.openPrivacySettings()
        #expect(system.openedURLs.map(\.absoluteString) == [
            "x-apple.systempreferences:com.apple.Bluetooth",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ])
    }

    @Test func routingAloneDoesNotConfirmCapture() async {
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        model.start()
        await model.startRouting()
        #expect(!model.welcomeState.isDone(.allowCapture))
        model.stopRouting()
    }

    @Test func unpairStepCanBeMarkedByHand() {
        model.welcomeActions.perform(.unpairJBL)
        #expect(model.welcomeState.isDone(.unpairJBL))
    }
}

/// Records what the model asks of the system instead of doing it.
@MainActor
final class FakeSystem {
    var openedURLs: [URL] = []
    var trusted = false
    var accessRequests = 0
    var launchAtLogin = false
    var failLaunchAtLogin = false
    var loginItemNeedsApproval = false
    var loginItemsOpened = 0

    struct Failure: Error {}

    var services: SystemServices {
        SystemServices(
            openURL: { [weak self] in self?.openedURLs.append($0) },
            isAccessibilityTrusted: { [weak self] in self?.trusted ?? false },
            requestAccessibility: { [weak self] in self?.accessRequests += 1 },
            isLaunchAtLoginEnabled: { [weak self] in self?.launchAtLogin ?? false },
            setLaunchAtLogin: { [weak self] enabled in
                guard let self else { return }
                if self.failLaunchAtLogin { throw Failure() }
                self.launchAtLogin = enabled
            },
            appName: { _ in nil },
            launchAtLoginRequiresApproval: { [weak self] in self?.loginItemNeedsApproval ?? false },
            openLoginItemsSettings: { [weak self] in self?.loginItemsOpened += 1 })
    }
}
