import AppKit
import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Background mode: menu bar item, Dock icon, reopen, and quit (SPEC 6a).
@MainActor
final class BackgroundModeTests {
    static let gripA = EngineTests.gripA
    static let gripB = EngineTests.gripB
    static let speakers = AppModelTests.speakers

    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let model: AppModel
    let system = FakeSystem()
    var windowsOpened = 0

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        model = AppModel(hal: hal, defaults: defaults, services: system.services)
        model.presentMainWindow = { [unowned self] in windowsOpened += 1 }
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func startWithGrips(default uid: String = AppModelTests.speakers.uid) {
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        hal.setDefault(uid: uid)
        model.start()
    }

    private func routeAndClose() async {
        startWithGrips()
        await model.startRouting()
        #expect(model.engine.state == .running)
        model.mainWindowDidClose()
    }

    // MARK: Closing the window

    @Test func closingWhileRoutingGoesToTheBackground() async {
        #expect(model.generalSettings.closeBehavior == .keepPlaying)
        await routeAndClose()
        #expect(model.isInBackground)
        #expect(system.activationPolicies == [.accessory])
        #expect(model.engine.state == .running)
    }

    @Test func closingWhileOffStaysANormalApp() {
        startWithGrips()
        model.mainWindowDidClose()
        #expect(!model.isInBackground)
        #expect(system.activationPolicies.isEmpty)
    }

    @Test func closingWithStopPlayingNeverGoesToTheBackground() async {
        model.generalSettings.closeBehavior = .stopPlaying
        await routeAndClose()
        #expect(!model.isInBackground)
        #expect(system.activationPolicies.isEmpty)
        #expect(model.engine.state == .idle)
    }

    @Test func closingTwiceSetsThePolicyOnce() async {
        await routeAndClose()
        model.mainWindowDidClose()
        #expect(system.activationPolicies == [.accessory])
    }

    // MARK: Reopening

    @Test func openDomineLeavesTheBackground() async {
        await routeAndClose()
        model.statusMenuActions.openMainWindow()
        #expect(!model.isInBackground)
        #expect(system.activationPolicies == [.accessory, .regular])
        #expect(windowsOpened == 1)
        #expect(system.activations == 1)
        #expect(model.engine.state == .running)
    }

    @Test func windowAppearingLeavesTheBackground() async {
        await routeAndClose()
        model.leaveBackground()
        model.leaveBackground()
        #expect(!model.isInBackground)
        #expect(system.activationPolicies == [.accessory, .regular])
    }

    @Test func reopeningTheAppShowsTheWindow() async {
        let delegate = AppDelegate()
        AppDelegate.model = model
        defer { AppDelegate.model = nil }
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))

        // A normal app with its window open: nothing to do.
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        #expect(windowsOpened == 0)
        // A normal app with its window closed: the Dock icon opens it.
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        #expect(windowsOpened == 1)
        #expect(system.activationPolicies.isEmpty)

        // In the background even an open Settings window counts as reopening.
        startWithGrips()
        await model.startRouting()
        model.mainWindowDidClose()
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        #expect(windowsOpened == 2)
        #expect(!model.isInBackground)
        #expect(system.activationPolicies == [.accessory, .regular])
    }

    // MARK: Quit

    @Test func quitAsksTheAppToTerminate() {
        model.statusMenuActions.quit()
        #expect(system.terminations == 1)
    }

    @Test func terminationStopsRoutingAndRestoresTheOutput() async {
        startWithGrips(default: Self.gripB.uid)
        await model.startRouting()
        #expect(hal.defaultOutputUID == Self.speakers.uid)
        model.mainWindowDidClose()
        model.appWillTerminate()
        #expect(model.engine.state == .idle)
        #expect(hal.defaultOutputUID == Self.gripB.uid)
    }

    // MARK: Auto-start in the background

    @Test func autoStartWorksInTheBackground() async {
        model.generalSettings.startWhenBothConnect = true
        await routeAndClose()
        #expect(model.isInBackground)

        // A Grip powers off: routing stops, the menu bar item stays.
        hal.remove(uid: Self.gripB.uid)
        model.syncWithCatalog()
        if model.engine.state.isActive { model.stopRouting() }
        #expect(model.isInBackground)

        hal.add(Self.gripB)
        model.syncWithCatalog()
        await model.autoStartTask?.value
        #expect(model.engine.state == .running)
        #expect(model.isInBackground)
    }

    // MARK: Defaults and output switching

    @Test func freshInstallAutoStartsAtLaunchAndSwitchesOutput() async {
        #expect(model.generalSettings.startWhenBothConnect)
        hal.add(FakeHAL.Device(uid: OutputRestorer.virtualOutputUID, name: "Domine",
                               transportType: kAudioDeviceTransportTypeVirtual))
        startWithGrips()
        await model.autoStartTask?.value
        #expect(model.engine.state == .running)
        #expect(hal.defaultOutputUID == OutputRestorer.virtualOutputUID)
        model.stopRouting()
        #expect(hal.defaultOutputUID == Self.speakers.uid)
    }

    // MARK: Menu quick controls

    @Test func menuMuteAndPresetEditsReachTheModel() async {
        startWithGrips()
        await model.startRouting()
        var edited = model.statusMenuState
        #expect(edited.isRouting)
        #expect(edited.preset == .flat)
        edited.isMuted = true
        edited.preset = .bassBoost
        model.applyStatusMenuEdit(edited)
        #expect(model.isMuted)
        #expect(model.pairSettings.effects == PairSettings.Preset.bassBoost.settings)
        #expect(model.statusMenuState.preset == .bassBoost)
    }

    @Test func menuSwapAndIdentifyCallTheModel() async {
        startWithGrips()
        await model.startRouting()
        let before = model.engine.swapSides
        model.statusMenuActions.swapSides()
        #expect(model.engine.swapSides != before)
        model.statusMenuActions.identifySpeaker(.frontLeft)
    }

    // MARK: Menu content

    @Test func menuShowsBothSpeakersConnected() async {
        startWithGrips()
        await model.startRouting()
        let state = model.statusMenuState
        #expect(state.statusText == "Playing")
        #expect(state.statusText == model.statusLine)
        #expect(state.isOn)
        #expect(state.left == StatusMenuSpeaker(
            position: "Front Left", deviceName: "JBL Grip",
            uidSuffix: OutputDevice.suffix(forUID: Self.gripA.uid), isConnected: true))
        #expect(state.right == StatusMenuSpeaker(
            position: "Front Right", deviceName: "JBL Grip",
            uidSuffix: OutputDevice.suffix(forUID: Self.gripB.uid), isConnected: true))
        #expect(state.masterVolume == Double(model.pairSettings.masterVolume))
    }

    @Test func menuShowsADisconnectedSpeaker() {
        startWithGrips()
        hal.remove(uid: Self.gripA.uid)
        model.syncWithCatalog()
        let state = model.statusMenuState
        #expect(!state.isOn)
        #expect(state.left.isConnected == false)
        #expect(state.left.deviceName == "JBL Grip")
        #expect(state.left.uidSuffix == OutputDevice.suffix(forUID: Self.gripA.uid))
        #expect(state.right.isConnected)
    }

    @Test func menuShowsUnchosenSpeakers() {
        model.start()
        let state = model.statusMenuState
        #expect(state.statusText == "Choose two speakers")
        #expect(state.left == StatusMenuSpeaker(
            position: "Front Left", deviceName: "Choose a speaker", uidSuffix: "", isConnected: false))
    }

    @Test func menuSwitchAndSliderDriveTheModel() async {
        startWithGrips()
        var edited = model.statusMenuState
        edited.masterVolume = 0.25
        model.applyStatusMenuEdit(edited)
        #expect(model.pairSettings.masterVolume == 0.25)
        #expect(model.engine.state == .idle)

        edited = model.statusMenuState
        edited.isOn = true
        model.applyStatusMenuEdit(edited)
        for _ in 0..<200 where model.engine.state != .running {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.engine.state == .running)

        edited = model.statusMenuState
        edited.isOn = false
        model.applyStatusMenuEdit(edited)
        #expect(model.engine.state == .idle)
        #expect(model.userTurnedRoutingOff)
    }
}

/// Reopening from the menu bar is ordered and reuses the one main window.
@MainActor
final class ReopenOrderTests {
    final class Recorder {
        var log: [String] = []
        var pending: [@MainActor @Sendable () -> Void] = []
        var hasWindow = false
    }

    let rec = Recorder()
    let model: AppModel
    let defaults: UserDefaults
    let suiteName = UUID().uuidString

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        let rec = rec
        var services = FakeSystem().services
        services.setActivationPolicy = { rec.log.append("policy \($0 == .regular ? "regular" : "other")") }
        services.activateApp = { rec.log.append("activate") }
        services.closeMenuPanel = { rec.log.append("closeMenu") }
        services.focusMainWindow = { rec.log.append("focus"); return rec.hasWindow }
        services.deferToNextTurn = { rec.pending.append($0) }
        model = AppModel(hal: FakeHAL(), defaults: defaults, services: services)
        model.presentMainWindow = { rec.log.append("open") }
    }

    deinit { UserDefaults().removePersistentDomain(forName: suiteName) }

    private func runPending() {
        let work = rec.pending
        rec.pending = []
        for item in work { item() }
    }

    @Test func policySwitchesBeforeTheWindowWork() {
        model.enterBackground()
        rec.log = []
        model.showMainWindow()
        #expect(rec.log == ["closeMenu", "policy regular"])
        runPending()
        #expect(rec.log == ["closeMenu", "policy regular", "focus", "open", "activate"])
    }

    @Test func existingWindowIsReusedNotReopened() {
        model.enterBackground()
        rec.hasWindow = true
        rec.log = []
        model.showMainWindow()
        runPending()
        #expect(rec.log == ["closeMenu", "policy regular", "focus", "activate"])
    }
}
