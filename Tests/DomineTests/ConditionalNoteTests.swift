import AppKit
import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Notes that depend on a condition show only while it holds, and go away
/// as soon as it clears.
@MainActor
final class ConditionalNoteTests {
    static let gripA = AppModelTests.gripA
    static let gripB = AppModelTests.gripB
    static let speakers = AppModelTests.speakers

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

    private func connect(_ device: FakeHAL.Device) {
        hal.add(device)
        model.syncWithCatalog()
    }

    // MARK: Accessibility

    @Test func accessibilityPromptNeedsKeysOnAndNoTrust() {
        #expect(!model.generalSettings.showsAccessibilityPrompt)
        model.generalSettings.volumeKeysEnabled = true
        #expect(model.generalSettings.showsAccessibilityPrompt)
        model.generalSettings.volumeKeysEnabled = false
        #expect(!model.generalSettings.showsAccessibilityPrompt)
    }

    @Test func accessibilityPromptHiddenWhenAlreadyTrusted() {
        system.trusted = true
        let model = AppModel(hal: hal, defaults: defaults, services: system.services)
        model.generalSettings.volumeKeysEnabled = true
        #expect(!model.generalSettings.showsAccessibilityPrompt)
        #expect(!model.volumeKeysNeedAccessibility)
    }

    @Test func becomingActiveClearsTheAccessibilityNotes() async {
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        model.start()
        model.generalSettings.volumeKeysEnabled = true
        await model.startRouting()
        #expect(model.mainWindowState.statusLine == "Playing, volume keys need Accessibility")
        system.trusted = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(!model.generalSettings.showsAccessibilityPrompt)
        #expect(model.setupState.accessibilityText == "Granted")
        #expect(model.mainWindowState.statusLine == "Playing")
        model.stopRouting()
    }

    @Test func trustIsPolledWhileKeysWaitEvenWhenRoutingIsOff() {
        #expect(model.trustPollTask == nil)
        model.generalSettings.volumeKeysEnabled = true
        #expect(model.trustPollTask != nil)
        system.trusted = true
        model.refreshSystemStatus()
        #expect(model.trustPollTask == nil)
        #expect(!model.generalSettings.showsAccessibilityPrompt)
    }

    @Test func turningKeysOffStopsThePoll() {
        model.generalSettings.volumeKeysEnabled = true
        model.generalSettings.volumeKeysEnabled = false
        #expect(model.trustPollTask == nil)
    }

    // MARK: Login item

    @Test func loginItemRowClearsAfterApproval() {
        system.loginItemNeedsApproval = true
        model.refreshSystemStatus()
        #expect(model.setupState.loginItemNeedsApproval)
        system.loginItemNeedsApproval = false
        model.refreshSystemStatus()
        #expect(!model.setupState.loginItemNeedsApproval)
    }

    @Test func turningOnLaunchAtLoginReadsApproval() {
        system.loginItemNeedsApproval = true
        model.generalSettings.launchAtLogin = true
        #expect(model.setupState.loginItemNeedsApproval)
    }

    // MARK: Grip pairing hint

    @Test func pairingHintGoesWhenTheSecondGripAppears() {
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        model.start()
        #expect(model.mainWindowState.bannerMessage == AppModel.gripPairingHint)
        #expect(model.assignSheetState(for: .frontLeft).footnote == AppModel.gripPairingHint)
        connect(Self.gripB)
        #expect(model.mainWindowState.bannerMessage == nil)
        #expect(model.assignSheetState(for: .frontLeft).footnote == nil)
    }

    @Test func noPairingHintWhenTheChosenPairIsPresent() {
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        model.start()
        model.setSpeakers(left: Self.gripA.uid, right: Self.speakers.uid)
        #expect(model.mainWindowState.bannerMessage == nil)
    }

    // MARK: No other output

    @Test func noOtherOutputClearsWhenAnotherOutputConnects() async {
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        hal.setDefault(uid: Self.gripA.uid)
        model.start()
        await model.startRouting()
        #expect(model.mainWindowState.statusLine == AppModel.noOtherOutputMessage)
        connect(Self.speakers)
        #expect(model.mainWindowState.statusLine != AppModel.noOtherOutputMessage)
    }

    @Test func noOtherOutputStaysWhileOnlyThePairExists() async {
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        hal.setDefault(uid: Self.gripA.uid)
        model.start()
        await model.startRouting()
        model.syncWithCatalog()
        #expect(model.mainWindowState.statusLine == AppModel.noOtherOutputMessage)
    }

    // MARK: Captions

    @Test func restoreCaptionOnlyWithAKnownPreviousOutput() {
        var state = GeneralSettingsState()
        #expect(state.restoreCaption == nil)
        state.previousOutputName = "MacBook Pro Speakers"
        #expect(state.restoreCaption == "Previous output: MacBook Pro Speakers")
    }
}
