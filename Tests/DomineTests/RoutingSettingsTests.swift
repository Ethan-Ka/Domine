import AppKit
import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Auto-start, close behavior, and the stored Exclusions settings.
@MainActor
final class RoutingSettingsTests {
    static let gripA = EngineTests.gripA
    static let gripB = EngineTests.gripB
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

    private func newModel() -> AppModel {
        AppModel(hal: hal, defaults: defaults, services: system.services)
    }

    /// Adds a device and lets the model see it now instead of on its next run loop turn.
    private func connect(_ device: FakeHAL.Device) {
        hal.add(device)
        model.syncWithCatalog()
    }

    private func disconnect(_ device: FakeHAL.Device) {
        hal.remove(uid: device.uid)
        model.syncWithCatalog()
    }

    private func waitForAutoStart() async {
        await model.autoStartTask?.value
        model.autoStartTask = nil
    }

    // MARK: Auto-start

    @Test func startsWhenBothSpeakersConnect() async {
        model.generalSettings.startWhenBothConnect = true
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        model.start()
        model.setSpeakers(left: Self.gripA.uid, right: Self.gripB.uid)
        #expect(model.autoStartTask == nil)
        connect(Self.gripB)
        await waitForAutoStart()
        #expect(model.engine.state == .running)
    }

    @Test func startsAtLaunchWhenBothAreAlreadyConnected() async {
        model.generalSettings.startWhenBothConnect = true
        model.setSpeakers(left: Self.gripA.uid, right: Self.gripB.uid)  // remembered pair
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        model.start()
        await waitForAutoStart()
        #expect(model.engine.state == .running)
    }

    @Test func offByDefault() async {
        model.setSpeakers(left: Self.gripA.uid, right: Self.gripB.uid)
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        model.start()
        #expect(model.autoStartTask == nil)
        #expect(model.engine.state == .idle)
    }

    @Test func turningRoutingOffBlocksAutoStartUntilASpeakerReconnects() async {
        model.generalSettings.startWhenBothConnect = true
        model.setSpeakers(left: Self.gripA.uid, right: Self.gripB.uid)
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        model.start()
        await waitForAutoStart()
        #expect(model.engine.state == .running)
        model.setRouting(false)
        #expect(model.engine.state == .idle)

        // Other device changes do not count as the speakers connecting.
        connect(FakeHAL.Device(uid: "USB-DAC-1", name: "USB DAC", transportType: kAudioDeviceTransportTypeUSB))
        #expect(model.autoStartTask == nil)

        disconnect(Self.gripB)
        #expect(model.autoStartTask == nil)
        connect(Self.gripB)
        await waitForAutoStart()
        #expect(model.engine.state == .running)
    }

    @Test func choosingANewPairIsNotAConnection() async {
        model.generalSettings.startWhenBothConnect = true
        model.setSpeakers(left: Self.gripA.uid, right: Self.gripB.uid)
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        model.start()
        await waitForAutoStart()
        model.setRouting(false)
        model.assign(Self.speakers.uid, to: .frontRight)
        model.syncWithCatalog()
        #expect(model.autoStartTask == nil)
        #expect(model.engine.state == .idle)
    }

    // MARK: Closing the window

    @Test func closingWithStopPlayingStopsRouting() async {
        model.generalSettings.closeBehavior = .stopPlaying
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        model.start()
        await model.startRouting()
        model.mainWindowDidClose()
        #expect(model.engine.state == .idle)
        #expect(model.userTurnedRoutingOff)
    }

    @Test func closingWithKeepPlayingKeepsRouting() async {
        #expect(model.generalSettings.closeBehavior == .keepPlaying)
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        model.start()
        await model.startRouting()
        model.mainWindowDidClose()
        #expect(model.engine.state == .running)
    }

    @Test func appKeepsRunningWithoutWindowsAndReopensFromTheDock() {
        var opened = 0
        AppDelegate.openMainWindow = { opened += 1 }
        defer { AppDelegate.openMainWindow = nil }
        let delegate = AppDelegate()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        #expect(opened == 1)
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        #expect(opened == 1)
    }

    // MARK: Exclusions

    @Test func exclusionEditsSurviveRelaunch() {
        model.addExclusion(bundleID: "us.zoom.xos")
        model.addExclusion(bundleID: "com.apple.FaceTime")
        model.addExclusion(bundleID: "com.hnc.Discord")
        model.exclusionsSettings.items[1].mode = .onlyDuringCalls
        model.exclusionsSettings.remove(bundleIDs: ["us.zoom.xos"])
        let reloaded = newModel()
        #expect(reloaded.exclusionsSettings.items == [
            ExclusionItem(bundleID: "com.apple.FaceTime", appName: "FaceTime", mode: .onlyDuringCalls),
            ExclusionItem(bundleID: "com.hnc.Discord", appName: "Discord"),
        ])
        #expect(reloaded.exclusionsSettings.availableSuggestions.map(\.bundleID)
            == ["us.zoom.xos", "com.microsoft.teams2"])
    }

    @Test func playThroughDeviceSurvivesRelaunchAndShowsWhenDisconnected() {
        let dac = FakeHAL.Device(uid: "USB-DAC-1", name: "USB DAC", transportType: kAudioDeviceTransportTypeUSB)
        hal.add(dac)
        hal.add(Self.gripA)
        model.start()
        model.exclusionsSettings.playThroughDeviceUID = dac.uid
        disconnect(dac)
        #expect(model.exclusionsSettings.outputChoices.last?.label == "USB DAC (\(OutputDevice.suffix(forUID: dac.uid))), not connected")

        let reloaded = newModel()
        reloaded.start()
        #expect(reloaded.exclusionsSettings.playThroughDeviceUID == dac.uid)
        #expect(reloaded.exclusionsSettings.outputChoices.map(\.uid) == [Self.gripA.uid, dac.uid])
    }

    // MARK: Volume keys status

    @Test func missingAccessibilityShowsInTheStatusLine() async {
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        model.start()
        model.generalSettings.volumeKeysEnabled = true
        await model.startRouting()
        #expect(model.mainWindowState.statusLine == "Playing, volume keys need Accessibility access")
        system.trusted = true
        model.refreshSystemStatus()
        #expect(model.mainWindowState.statusLine == "Playing")
    }
}
