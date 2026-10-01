import AppKit
import Foundation
import Testing
@testable import Domine

/// Each permission the UI shows is read fresh when shown, and the fix path
/// for a stale Accessibility entry is offered.
@MainActor
final class PermissionDetectionTests {
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

    private func becomeActive() {
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: Accessibility, fresh reads

    @Test func activationReadsTrust() {
        model.start()
        let reads = system.trustReads
        system.trusted = true
        becomeActive()
        #expect(system.trustReads > reads)
        #expect(model.generalSettings.accessibilityGranted)
    }

    @Test func settingsAppearingReadsTrust() {
        system.trusted = true
        model.settingsDidAppear()
        #expect(model.generalSettings.accessibilityGranted)
        model.settingsDidDisappear()
    }

    @Test func setupRowReadsTrustOnEveryRender() {
        #expect(!model.setupState.accessibilityGranted)
        let reads = system.trustReads
        _ = model.setupState
        #expect(system.trustReads == reads + 1)
        system.trusted = true
        #expect(model.setupState.accessibilityGranted)
    }

    @Test func volumeKeysToggleReadsTrust() {
        system.trusted = true
        #expect(!model.generalSettings.accessibilityGranted)
        model.generalSettings.volumeKeysEnabled = true
        #expect(model.generalSettings.accessibilityGranted)
        #expect(!model.generalSettings.showsAccessibilityPrompt)
    }

    @Test func noteDisappearsAsSoonAsTrustArrives() {
        #expect(model.setupState.accessibilityNote == "Switch on Domine in the list.")
        system.trusted = true
        #expect(model.setupState.accessibilityNote == nil)
        #expect(model.setupState.accessibilityText == "Granted")
    }

    // MARK: Accessibility, polling

    @Test func pollRunsOnlyWhileANoteIsVisible() {
        #expect(model.trustPollTask == nil)
        model.settingsDidAppear()
        #expect(model.trustPollTask != nil)
        model.settingsDidDisappear()
        #expect(model.trustPollTask == nil)
        model.generalSettings.volumeKeysEnabled = true
        #expect(model.trustPollTask != nil)
        model.generalSettings.volumeKeysEnabled = false
        #expect(model.trustPollTask == nil)
    }

    @Test func noPollOnceTrusted() {
        system.trusted = true
        model.settingsDidAppear()
        #expect(model.trustPollTask == nil)
        model.settingsDidDisappear()
    }

    @Test func pollPicksUpAGrantWhileSettingsIsOpen() async {
        model.trustPollInterval = .milliseconds(5)
        model.settingsDidAppear()
        system.trusted = true
        for _ in 0..<400 where !model.generalSettings.accessibilityGranted {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.generalSettings.accessibilityGranted)
        #expect(model.trustPollTask == nil)
        model.settingsDidDisappear()
    }

    // MARK: Accessibility, Grant Access and stale entries

    @Test func grantAccessPromptsAndOpensThePane() {
        model.setupActions().grantAccessibility()
        #expect(system.accessRequests == 1)
        #expect(system.openedURLs == [VolumeKeyTap.accessibilitySettingsURL])
        model.generalSettingsActions.grantAccessibility()
        #expect(system.accessRequests == 2)
        #expect(system.openedURLs == [VolumeKeyTap.accessibilitySettingsURL, VolumeKeyTap.accessibilitySettingsURL])
    }

    @Test func untrustedAfterSystemSettingsOffersReveal() {
        model.start()
        becomeActive()
        #expect(!model.setupState.accessibilityLikelyStale)

        model.setupActions().grantAccessibility()
        becomeActive()
        #expect(model.setupState.accessibilityLikelyStale)
        #expect(model.setupState.accessibilityNote == "Remove Domine from the list, then drag this copy in.")
        model.setupActions().revealApp()
        #expect(system.revealedURLs == [Bundle.main.bundleURL])

        system.trusted = true
        #expect(!model.setupState.accessibilityLikelyStale)
        becomeActive()
        #expect(!model.accessibilityLikelyStale)
        #expect(model.setupState.accessibilityNote == nil)
    }

    @Test func trustedOnReturnIsNotStale() {
        model.start()
        model.setupActions().grantAccessibility()
        system.trusted = true
        becomeActive()
        #expect(!model.accessibilityLikelyStale)
        #expect(!model.awaitingAccessibilityGrant)
    }

    // MARK: Audio capture

    @Test func captureStatusResetsWhenTheSignatureChanges() {
        let store = SettingsStore(defaults: defaults)
        let working = AudioCapturePermission(hal: hal, store: store, signature: "A")
        working.markWorking()
        #expect(store.audioCaptureSignature == "A")
        #expect(AudioCapturePermission(hal: hal, store: store, signature: "A").status == .working)

        let rebuilt = AudioCapturePermission(hal: hal, store: store, signature: "B")
        #expect(rebuilt.status == .unknown)
        #expect(!store.audioCaptureWorking)
        #expect(store.audioCaptureSignature == "B")
    }

    @Test func captureStatusWithoutARecordedSignatureResets() {
        let store = SettingsStore(defaults: defaults)
        store.audioCaptureWorking = true
        #expect(AudioCapturePermission(hal: hal, store: store, signature: "A").status == .unknown)
    }

    @Test func modelPassesTheRunningSignature() {
        model.captureAccess.markWorking()
        #expect(model.store.audioCaptureSignature == system.signature)
        system.signature = "identifier com.ethankawley.Domine and cdhash H\"bb\""
        let rebuilt = AppModel(hal: hal, defaults: defaults, services: system.services)
        #expect(rebuilt.captureAccess.status == .unknown)
    }

    @Test func captureTextNeverSaysDenied() {
        for status in [AudioCaptureStatus.unknown, .notConfirmed, .working] {
            for checking in [false, true] {
                let state = SetupState(captureStatus: status, isCheckingCapture: checking)
                #expect(!state.captureText.lowercased().contains("denied"))
            }
        }
    }

    @Test func clickTestDoesNotConfirmCapture() async {
        hal.add(AppModelTests.gripA)
        hal.add(AppModelTests.gripB)
        model.start()
        await model.startRouting()
        model.engine.clickTest = true
        var heard = false
        for _ in 0..<40 {
            let input = FakeBufferList(channelsPerBuffer: [2], frames: 512)
            let output = FakeBufferList(channelsPerBuffer: [2, 2], frames: 512)
            hal.render(input: input, output: output)
            let peaks = model.readMeterPeaks()
            if peaks.0 > 0 || peaks.1 > 0 { heard = true }
        }
        #expect(heard)  // the clicks reached the meters
        #expect(model.captureAccess.status == .unknown)
        model.stopRouting()
    }

    // MARK: Microphone

    /// Nothing uses the microphone yet (calibration is planned, SPEC 12), so
    /// no screen shows a row for it.
    @Test func noMicrophoneRow() {
        let labels = Mirror(reflecting: SetupState()).children.compactMap(\.label)
            + Mirror(reflecting: GeneralSettingsState()).children.compactMap(\.label)
            + WelcomeStep.Kind.allCases.map { String(describing: $0) }
        #expect(!labels.isEmpty)
        #expect(!labels.contains { $0.lowercased().contains("microphone") || $0.lowercased().contains("mic") })
    }
}
