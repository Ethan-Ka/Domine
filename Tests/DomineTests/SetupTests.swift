import Foundation
import Testing
@testable import Domine

/// Settings > General, Setup: replaying the checklist and the prompt rows.
@MainActor
final class SetupTests {
    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let system = FakeSystem()
    let model: AppModel

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        model = AppModel(hal: hal, defaults: defaults, services: system.services)
        model.captureAccess.wait = {}
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test func showSetupAgainFlipsTheFlagAndPresentsTheSheet() {
        model.completeWelcome()
        #expect(model.store.hasCompletedWelcome)
        #expect(!model.showsWelcome)

        var mainWindowShown = 0
        model.setupActions(showMainWindow: { mainWindowShown += 1 }).showSetupAgain()
        #expect(!model.store.hasCompletedWelcome)
        #expect(model.showsWelcome)
        #expect(mainWindowShown == 1)
    }

    @Test func showSetupAgainClearsTheManualUnpairMark() {
        model.welcomeActions.perform(.unpairJBL)
        model.showSetupAgain()
        #expect(!model.welcomeState.isDone(.unpairJBL))
    }

    @Test func speakersRowCountsGrips() {
        model.start()
        #expect(model.setupState.connectedGrips == 0)
        #expect(model.setupState.speakersText == "No JBL Grip connected")
        hal.add(AppModelTests.speakers)
        hal.add(AppModelTests.gripA)
        #expect(model.setupState.speakersText == "1 JBL Grip connected")
        hal.add(AppModelTests.gripB)
        #expect(model.setupState.speakersText == "2 JBL Grips connected")
    }

    @Test func accessibilityRowFollowsTrust() {
        #expect(model.setupState.accessibilityText == "Not granted")
        system.trusted = true
        model.refreshSystemStatus()
        #expect(model.setupState.accessibilityGranted)
        #expect(model.setupState.accessibilityText == "Granted")
        model.setupActions().grantAccessibility()
        #expect(system.accessRequests == 1)
    }

    @Test func loginItemRowOnlyWhenApprovalNeeded() {
        #expect(!model.setupState.loginItemNeedsApproval)
        system.loginItemNeedsApproval = true
        #expect(model.setupState.loginItemNeedsApproval)
        model.setupActions().openLoginItems()
        #expect(system.loginItemsOpened == 1)
    }

    @Test func captureRowFollowsTheProbe() async {
        #expect(model.setupState.captureStatus == .unknown)
        #expect(model.setupState.captureText == "Not confirmed")
        await model.requestCaptureAccess()
        #expect(model.setupState.captureStatus == .notConfirmed)
        #expect(model.welcomeState.showsPrivacySettings)
        model.captureAccess.markWorking()
        #expect(model.setupState.captureText == "Working")
        #expect(!model.welcomeState.showsPrivacySettings)
        #expect(model.welcomeState.isDone(.allowCapture))
    }

    @Test func settingsButtonsOpenSystemSettings() {
        let actions = model.setupActions()
        actions.openBluetoothSettings()
        actions.openPrivacySettings()
        #expect(system.openedURLs == [SystemServices.bluetoothSettingsURL, SystemServices.audioCaptureSettingsURL])
    }

    @Test func meterAudioConfirmsCapture() async {
        hal.add(AppModelTests.gripA)
        hal.add(AppModelTests.gripB)
        model.start()
        await model.startRouting()
        let input = FakeBufferList(channelsPerBuffer: [2], frames: 4, fill: 0.3)
        let output = FakeBufferList(channelsPerBuffer: [2, 2], frames: 4)
        hal.render(input: input, output: output)
        _ = model.readMeterPeaks()
        #expect(model.captureAccess.status == .working)
        #expect(model.store.audioCaptureWorking)
        model.stopRouting()
    }

    @Test func testToneDoesNotConfirmCapture() async {
        hal.add(AppModelTests.gripA)
        hal.add(AppModelTests.gripB)
        model.start()
        await model.startRouting()
        model.toggleTestTone(.left)
        let input = FakeBufferList(channelsPerBuffer: [2], frames: 64)
        let output = FakeBufferList(channelsPerBuffer: [2, 2], frames: 64)
        hal.render(input: input, output: output)
        _ = model.readMeterPeaks()
        #expect(model.captureAccess.status == .unknown)
        model.stopRouting()
    }

    @Test func setupStateTexts() {
        var state = SetupState()
        state.connectedGrips = 3
        #expect(state.speakersText == "3 JBL Grips connected")
        state.isCheckingCapture = true
        #expect(state.captureText == "Checking…")
    }
}
