import AppKit
import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Moving the default output off the routed speakers and back (SPEC 3b, 4c).
@MainActor
final class OutputRestoreTests {
    static let gripA = EngineTests.gripA
    static let gripB = EngineTests.gripB
    static let speakers = AppModelTests.speakers
    static let dac = FakeHAL.Device(uid: "USB-DAC-1", name: "USB DAC", transportType: kAudioDeviceTransportTypeUSB)

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

    private func add(_ devices: FakeHAL.Device..., default uid: String) {
        devices.forEach { hal.add($0) }
        hal.setDefault(uid: uid)
        model.start()
    }

    // MARK: Start and stop

    @Test func startSavesThePreviousOutputAndStopRestoresIt() async {
        add(Self.speakers, Self.dac, Self.gripA, Self.gripB, default: Self.speakers.uid)
        await model.startRouting()
        #expect(model.engine.state == .running)
        #expect(model.store.previousOutputUID == Self.speakers.uid)
        #expect(hal.defaultOutputWrites.isEmpty)
        #expect(model.generalSettings.previousOutputName == "MacBook Pro Speakers")

        hal.setDefault(uid: Self.dac.uid)
        model.stopRouting()
        #expect(hal.defaultOutputUID == Self.speakers.uid)
        #expect(!model.store.outputNeedsRestore)
    }

    @Test func defaultOnARoutedSpeakerMovesToTheBuiltInOutputBeforeTheTap() async {
        add(Self.dac, Self.speakers, Self.gripA, Self.gripB, default: Self.gripB.uid)
        await model.startRouting()
        #expect(model.engine.state == .running)
        #expect(hal.defaultOutputUID == Self.speakers.uid)
        #expect(model.store.previousOutputUID == Self.gripB.uid)

        model.stopRouting()
        #expect(hal.defaultOutputUID == Self.gripB.uid)
    }

    static let virtualOutput = FakeHAL.Device(
        uid: OutputRestorer.virtualOutputUID, name: "Domine", transportType: kAudioDeviceTransportTypeVirtual)

    @Test func virtualOutputIsPreferredWhenInstalled() async {
        model.exclusionsSettings.playThroughDeviceUID = Self.dac.uid
        add(Self.speakers, Self.dac, Self.virtualOutput, Self.gripA, Self.gripB, default: Self.gripA.uid)
        #expect(model.catalog.device(uid: OutputRestorer.virtualOutputUID) == nil)  // hidden from the list
        await model.startRouting()
        #expect(hal.defaultOutputUID == OutputRestorer.virtualOutputUID)
        hal.setDefault(uid: Self.gripB.uid)
        #expect(hal.defaultOutputUID == OutputRestorer.virtualOutputUID)
        model.stopRouting()
        #expect(hal.defaultOutputUID == Self.gripA.uid)
    }

    @Test func virtualOutputAsPreviousOutputIsRestored() async {
        add(Self.speakers, Self.virtualOutput, Self.gripA, Self.gripB, default: OutputRestorer.virtualOutputUID)
        await model.startRouting()
        #expect(model.store.previousOutputUID == OutputRestorer.virtualOutputUID)
        hal.setDefault(uid: Self.speakers.uid)
        model.stopRouting()
        #expect(hal.defaultOutputUID == OutputRestorer.virtualOutputUID)
    }

    @Test func excludedAppsDeviceWinsWhenSet() async {
        model.exclusionsSettings.playThroughDeviceUID = Self.dac.uid
        add(Self.speakers, Self.dac, Self.gripA, Self.gripB, default: Self.gripA.uid)
        await model.startRouting()
        #expect(hal.defaultOutputUID == Self.dac.uid)
    }

    @Test func refusesToStartWhenOnlyTheSpeakersExist() async {
        add(Self.gripA, Self.gripB, default: Self.gripA.uid)
        await model.startRouting()
        #expect(model.engine.state == .idle)
        #expect(model.mainWindowState.statusLine == AppModel.noOtherOutputMessage)
        #expect(hal.liveTapCount == 0)
        #expect(hal.defaultOutputUID == Self.gripA.uid)
        #expect(!model.store.outputNeedsRestore)
    }

    @Test func defaultSetBackToASpeakerWhileRoutingIsMovedOffAgain() async {
        add(Self.speakers, Self.gripA, Self.gripB, default: Self.speakers.uid)
        await model.startRouting()
        hal.setDefault(uid: Self.gripA.uid)
        #expect(hal.defaultOutputUID == Self.speakers.uid)
        model.stopRouting()
        // After stopping, the default is free to go anywhere.
        hal.setDefault(uid: Self.gripA.uid)
        #expect(hal.defaultOutputUID == Self.gripA.uid)
    }

    @Test func restoreOffLeavesTheCurrentDefault() async {
        model.generalSettings.restorePreviousOutput = false
        add(Self.speakers, Self.gripA, Self.gripB, default: Self.gripB.uid)
        await model.startRouting()
        model.stopRouting()
        #expect(hal.defaultOutputUID == Self.speakers.uid)
        #expect(!model.store.outputNeedsRestore)
    }

    @Test func previousOutputThatIsGoneIsNotRestored() async {
        add(Self.speakers, Self.dac, Self.gripA, Self.gripB, default: Self.dac.uid)
        await model.startRouting()
        hal.setDefault(uid: Self.speakers.uid)
        hal.remove(uid: Self.dac.uid)
        model.stopRouting()
        #expect(hal.defaultOutputUID == Self.speakers.uid)
    }

    @Test func failedStartPutsThePreviousOutputBack() async {
        hal.failures[.createTap] = kAudioHardwareUnspecifiedError
        add(Self.speakers, Self.gripA, Self.gripB, default: Self.gripB.uid)
        await model.startRouting()
        #expect(model.engine.state != .running)
        #expect(hal.defaultOutputUID == Self.gripB.uid)
    }

    @Test func quitRestoresThePreviousOutput() async {
        add(Self.speakers, Self.gripA, Self.gripB, default: Self.gripA.uid)
        await model.startRouting()
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(hal.defaultOutputUID == Self.gripA.uid)
    }

    @Test func launchAfterACrashRestoresThePreviousOutput() {
        let store = SettingsStore(defaults: defaults)
        store.previousOutputUID = Self.gripA.uid
        store.outputNeedsRestore = true
        add(Self.speakers, Self.gripA, Self.gripB, default: Self.speakers.uid)
        #expect(hal.defaultOutputUID == Self.gripA.uid)
        #expect(!store.outputNeedsRestore)
    }

    @Test func cleanLaunchLeavesTheDefaultAlone() {
        SettingsStore(defaults: defaults).previousOutputUID = Self.gripA.uid
        add(Self.speakers, Self.gripA, Self.gripB, default: Self.speakers.uid)
        #expect(hal.defaultOutputUID == Self.speakers.uid)
    }

    // MARK: Choosing

    static func output(_ device: FakeHAL.Device, id: AudioObjectID) -> OutputDevice {
        OutputDevice(uid: device.uid, id: id, name: device.name, outputChannels: 2, transportType: device.transportType)
    }

    @Test func fallbackOrder() {
        let a = Self.output(Self.gripA, id: 1)
        let b = Self.output(Self.gripB, id: 2)
        let builtIn = Self.output(Self.speakers, id: 3)
        let dac = Self.output(Self.dac, id: 4)
        let pair: Set = [a.uid, b.uid]
        let all = [a, b, dac, builtIn]
        func pick(_ playThrough: String?, _ previous: String?, _ outputs: [OutputDevice] = all) -> String? {
            OutputRestorer.fallbackOutput(pair: pair, playThroughUID: playThrough, previousUID: previous, outputs: outputs)?.uid
        }
        #expect(pick(dac.uid, builtIn.uid) == dac.uid)
        #expect(pick(a.uid, dac.uid) == dac.uid)  // a play-through device in the pair is skipped
        #expect(pick(nil, dac.uid) == dac.uid)
        #expect(pick(nil, b.uid) == builtIn.uid)
        #expect(pick(nil, nil) == builtIn.uid)
        #expect(pick(nil, nil, [a, dac, b]) == dac.uid)
        #expect(pick(nil, nil, [a, b]) == nil)
        let aggregate = OutputDevice(uid: DeviceCatalog.domineUIDPrefix + "agg", id: 9, name: "Domine",
                                     outputChannels: 4, transportType: kAudioDeviceTransportTypeAggregate)
        #expect(pick(nil, nil, [a, b, aggregate]) == nil)
    }
}
