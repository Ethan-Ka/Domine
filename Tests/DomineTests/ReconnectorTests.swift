import XCTest
@testable import Domine

private final class FakeConnector: BluetoothConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var onConnect: (@Sendable (String) async -> Void)?
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    private func record(_ s: String) { lock.lock(); _calls.append(s); lock.unlock() }

    func connect(_ address: BluetoothAddress) async -> Bool {
        record(address.string)
        await onConnect?(address.string)
        return true
    }
}

private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [Duration] = []
    var delays: [Duration] { lock.lock(); defer { lock.unlock() }; return _delays }
    func add(_ d: Duration) { lock.lock(); _delays.append(d); lock.unlock() }
}

@MainActor
final class ReconnectorTests: XCTestCase {
    private let uid = "AA-BB-CC-DD-EE-FF:output"
    private let address = "aa-bb-cc-dd-ee-ff"

    private func make(enabled: @escaping @MainActor () -> Bool = { true })
        -> (SpeakerReconnector, FakeConnector, SleepLog)
    {
        let connector = FakeConnector()
        let log = SleepLog()
        let reconnector = SpeakerReconnector(connector: connector, isEnabled: enabled, sleep: { log.add($0) })
        return (reconnector, connector, log)
    }

    func testRetriesOnScheduleAndGivesUpAfterTenMinutes() async {
        let (reconnector, connector, log) = make()
        reconnector.update(missing: [uid])
        await reconnector.waitForRetries()
        // 5 s, then 30 s steps: 5 + 30 * 19 = 575 s; the next would pass 600 s.
        XCTAssertEqual(log.delays.first, .seconds(5))
        XCTAssertEqual(Set(log.delays.dropFirst()), [.seconds(30)])
        XCTAssertEqual(log.delays.count, 20)
        XCTAssertEqual(connector.calls.count, 20)
        XCTAssertEqual(Set(connector.calls), [address])
    }

    func testStopsWhenDeviceReturns() async {
        let (reconnector, connector, _) = make()
        connector.onConnect = { _ in await MainActor.run { reconnector.update(missing: []) } }
        reconnector.update(missing: [uid])
        await reconnector.waitForRetries()
        XCTAssertEqual(connector.calls.count, 1)
    }

    func testIgnoresNonBluetoothUIDs() async {
        let (reconnector, connector, log) = make()
        reconnector.update(missing: ["BuiltInSpeakerDevice", "AppleUSBAudioEngine:Foo:1"])
        await reconnector.waitForRetries()
        XCTAssertTrue(connector.calls.isEmpty)
        XCTAssertTrue(log.delays.isEmpty)
    }

    func testRespectsSetting() async {
        let (reconnector, connector, _) = make(enabled: { false })
        reconnector.update(missing: [uid])
        await reconnector.waitForRetries()
        XCTAssertTrue(connector.calls.isEmpty)
    }

    func testReconnectNowTriesOnceImmediatelyEvenWhenSettingIsOff() async {
        let (reconnector, connector, log) = make(enabled: { false })
        await reconnector.reconnectNow(uid: uid).value
        XCTAssertEqual(connector.calls, [address])
        XCTAssertTrue(log.delays.isEmpty)
        XCTAssertTrue(reconnector.connecting.isEmpty)
    }
}
