import CoreAudio
import Foundation
import Testing
@testable import Domine

/// A surround set change counts like a mode switch for auto-start, the
/// refusal, and the reconnector; a saved set loads in the order asked for.
@MainActor
final class SurroundSetChangeTests {
    static let gripA = EngineTests.gripA
    static let gripB = EngineTests.gripB
    static let gripC = SurroundModelTests.device(3)
    static let speakers = AppModelTests.speakers

    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let system = FakeSystem()
    let connector = SetChangeConnector()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit { UserDefaults().removePersistentDomain(forName: suiteName) }

    private func makeModel() -> AppModel {
        let model = AppModel(hal: hal, defaults: defaults, services: system.services,
                             bluetooth: connector, reconnectSleep: { _ in })
        model.generalSettings.startWhenBothConnect = false
        return model
    }

    /// A model in Surround on the pair A and B, both connected.
    private func surroundModel() -> AppModel {
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        let model = makeModel()
        model.start()
        model.setSpeakers(left: Self.gripA.uid, right: Self.gripB.uid)
        model.setRoutingMode(.surround)
        model.syncWithCatalog()
        return model
    }

    // MARK: Auto-start, refusal, reconnector

    @Test func speakerConnectingAfterASetChangeAutoStarts() async {
        let model = surroundModel()
        model.generalSettings.startWhenBothConnect = true
        model.addSurroundSpeaker(uid: Self.gripC.uid)
        #expect(model.autoStartTask == nil)
        hal.add(Self.gripC)
        model.syncWithCatalog()
        await model.autoStartTask?.value
        #expect(model.engine.state == .running)
        #expect(model.engine.surroundRoute == [Self.gripA.uid, Self.gripB.uid, Self.gripC.uid])
    }

    @Test func selectingASavedSetCountsTheSameWay() async {
        let model = surroundModel()
        model.generalSettings.startWhenBothConnect = true
        model.selectSurroundSet([Self.gripA.uid, Self.gripB.uid, Self.gripC.uid])
        #expect(model.autoStartTask == nil)
        hal.add(Self.gripC)
        model.syncWithCatalog()
        await model.autoStartTask?.value
        #expect(model.engine.state == .running)
    }

    @Test func setChangeClearsTheRefusal() async {
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        hal.setDefault(uid: Self.gripA.uid)
        let model = makeModel()
        model.start()
        model.setSpeakers(left: Self.gripA.uid, right: Self.gripB.uid)
        model.setRoutingMode(.surround)
        await model.startRouting()
        #expect(model.mainWindowState.statusLine == AppModel.noOtherOutputMessage)
        model.addSurroundSpeaker(uid: Self.gripC.uid)
        #expect(model.mainWindowState.statusLine != AppModel.noOtherOutputMessage)
    }

    @Test func setChangeUpdatesWhichSpeakersReconnect() async {
        let model = surroundModel()
        await model.reconnector.waitForRetries()
        #expect(connector.calls.isEmpty)
        model.addSurroundSpeaker(uid: "AA-BB-CC-DD-EE-FF:output")
        await model.reconnector.waitForRetries()
        #expect(!connector.calls.isEmpty)
    }

    // MARK: Order of a saved set

    @Test func savedSetLoadsInTheRequestedOrderWithItsValues() {
        let model = makeModel()
        for uid in ["A", "B", "C"] { model.addSurroundSpeaker(uid: uid) }
        model.moveSurroundSpeaker(uid: "C", azimuth: 100, distance: 4)
        model.setSurroundTrim(uid: "B", 0.25)
        model.setSurroundOffset(uid: "C", ms: 12)
        model.removeSurroundSpeaker(uid: "C")
        #expect(model.surroundSettings.uids == ["A", "B"])

        model.selectSurroundSet(["C", "B", "A"])
        let s = model.surroundSettings
        #expect(s.uids == ["C", "B", "A"])
        #expect(s.speakers.map(\.azimuth) == [100, 30, -30])
        #expect(s.speakers[0].distance == 4)
        #expect(s.trims == ["B": 0.25])
        #expect(s.offsetsMs == ["C": 12])
        #expect(model.engine.surroundSpeakers.map(\.uid) == ["C", "B", "A"])
    }

    @Test func lastSetLoadsInItsSavedOrder() {
        let store = SettingsStore(defaults: defaults)
        var saved = SurroundSettings(uids: ["A", "B"])
        saved.trims = ["A": 0.5]
        store.setSurroundSettings(saved)
        store.lastSurroundUIDs = ["B", "A"]
        let model = makeModel()
        #expect(model.surroundSettings.uids == ["B", "A"])
        #expect(model.surroundSettings.speakers.map(\.azimuth) == [30, -30])
        #expect(model.surroundSettings.trims == ["A": 0.5])
    }
}

final class SetChangeConnector: BluetoothConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    func connect(_ address: BluetoothAddress) async -> Bool {
        record(address.string)
        return false
    }

    private func record(_ s: String) {
        lock.lock(); _calls.append(s); lock.unlock()
    }
}
