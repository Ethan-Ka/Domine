import Foundation
import Testing
@testable import Domine

@MainActor
final class FakeBluetoothRadio: BluetoothRadio {
    var paired: [BluetoothSpeaker] = []
    var connectResult = true
    var pairResult = true
    var found: ((BluetoothSpeaker) -> Void)?
    var finish: (() -> Void)?
    var stopCount = 0
    /// Called inside each action, before it returns.
    var duringAction: () -> Void = {}

    func pairedSpeakers() -> [BluetoothSpeaker] { paired }

    func startSearch(found: @escaping @MainActor (BluetoothSpeaker) -> Void,
                     finished: @escaping @MainActor () -> Void) {
        self.found = found
        finish = finished
    }

    func stopSearch() { stopCount += 1 }

    func connect(_ address: BluetoothAddress) async -> Bool {
        duringAction()
        guard connectResult else { return false }
        setConnected(address, true)
        return true
    }

    func disconnect(_ address: BluetoothAddress) async -> Bool {
        duringAction()
        setConnected(address, false)
        return true
    }

    func pair(_ address: BluetoothAddress) async -> Bool {
        duringAction()
        guard pairResult else { return false }
        paired.append(BluetoothSpeaker(address: address, name: "JBL Grip", isPaired: true, isConnected: true))
        return true
    }

    private func setConnected(_ address: BluetoothAddress, _ value: Bool) {
        if let index = paired.firstIndex(where: { $0.address == address }) { paired[index].isConnected = value }
    }
}

@MainActor
final class BluetoothSpeakersModelTests {
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let store: SettingsStore
    let radio = FakeBluetoothRadio()
    let model: BluetoothSpeakersModel

    let a = BluetoothAddress(deviceUID: "70-99-1c-11-b9-1c:output")!
    let b = BluetoothAddress(deviceUID: "70-99-1c-11-4f-2a")!

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        store = SettingsStore(defaults: defaults)
        model = BluetoothSpeakersModel(radio: radio, store: store)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func speaker(_ address: BluetoothAddress, paired: Bool = true, connected: Bool = false) -> BluetoothSpeaker {
        BluetoothSpeaker(address: address, name: "JBL Grip", isPaired: paired, isConnected: connected)
    }

    @Test func refreshReadsPairedAndSplitsRemembered() {
        radio.paired = [speaker(a, connected: true), speaker(b)]
        model.remember(uid: a.string, name: "JBL Grip")
        model.refresh()
        #expect(model.paired.count == 2)
        #expect(model.mySpeakers.map(\.address) == [a])
        #expect(model.mySpeakers.first?.isConnected == true)
        #expect(model.otherPaired.map(\.address) == [b])
    }

    @Test func rememberedSpeakerOutOfRangeShowsNotConnected() {
        model.remember(uid: a.string, name: "JBL Grip")
        model.refresh()
        #expect(model.mySpeakers == [speaker(a, paired: false, connected: false)])
    }

    @Test func searchAddsUniqueNearbyOnly() {
        radio.paired = [speaker(b)]
        model.refresh()
        model.search()
        #expect(model.isSearching)
        radio.found?(speaker(a, paired: false))
        radio.found?(speaker(a, paired: false))
        radio.found?(speaker(b, paired: false))
        #expect(model.nearby.map(\.address) == [a])
        radio.finish?()
        #expect(!model.isSearching)
        #expect(model.hasSearched)
    }

    @Test func searchClearsNearbyAndStopEndsIt() {
        model.search()
        radio.found?(speaker(a, paired: false))
        model.search()
        #expect(model.nearby.isEmpty)
        model.stop()
        #expect(!model.isSearching)
        radio.found?(speaker(a, paired: false))
        #expect(model.nearby.isEmpty)
    }

    @Test func pairMovesToPairedAndRemembers() async {
        model.search()
        radio.found?(speaker(a, paired: false))
        await model.pair(a)
        #expect(model.nearby.isEmpty)
        #expect(model.paired.map(\.address) == [a])
        #expect(model.mySpeakers.map(\.address) == [a])
        #expect(store.rememberedSpeakers == [RememberedSpeaker(address: a.string, name: "JBL Grip")])
    }

    @Test func connectAddsToMySpeakers() async {
        radio.paired = [speaker(b)]
        model.refresh()
        await model.connect(b)
        #expect(model.mySpeakers.map(\.address) == [b])
        #expect(model.mySpeakers.first?.isConnected == true)
        #expect(model.otherPaired.isEmpty)
        #expect(model.lastError == nil)
    }

    @Test func connectFailureSetsLastError() async {
        radio.paired = [speaker(a)]
        radio.connectResult = false
        model.refresh()
        await model.connect(a)
        #expect(model.lastError == "Couldn't connect to JBL Grip (B91C).")
        #expect(model.remembered.isEmpty)
        #expect(model.busy.isEmpty)
    }

    @Test func busyIsSetDuringAction() async {
        radio.paired = [speaker(a)]
        model.refresh()
        var seen: Set<String> = []
        radio.duringAction = { [model] in seen = model.busy }
        await model.connect(a)
        #expect(seen == [a.string])
        #expect(model.busy.isEmpty)
    }

    @Test func forgetRemovesFromListAndStore() {
        model.remember(uid: a.string, name: "JBL Grip")
        model.remember(uid: b.string, name: "JBL Grip")
        model.forget(a)
        #expect(model.remembered.map(\.address) == [b.string])
        #expect(store.rememberedSpeakers.map(\.address) == [b.string])
    }

    @Test func rememberedListRoundTripsThroughStore() {
        model.remember(uid: "70-99-1C-11-4F-2A:output", name: "JBL Grip")
        model.remember(uid: a.string, name: "Kitchen")
        model.remember(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
        let reloaded = BluetoothSpeakersModel(radio: radio, store: SettingsStore(defaults: defaults))
        #expect(reloaded.remembered == [
            RememberedSpeaker(address: b.string, name: "JBL Grip"),
            RememberedSpeaker(address: a.string, name: "Kitchen"),
        ])
    }

    @Test func assigningSpeakersRemembersThem() {
        let appModel = AppModel(hal: FakeHAL(), defaults: defaults, services: FakeSystem().services, radio: radio)
        appModel.setSpeakers(left: "70-99-1c-11-b9-1c:output", right: "BuiltInSpeakerDevice")
        #expect(appModel.bluetoothSpeakers.remembered.map(\.address) == [a.string])
    }
}
