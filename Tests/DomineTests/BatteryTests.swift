import Foundation
import Testing
@testable import Domine

private struct FakeBattery: BatteryReading {
    var levels: [String: Int]
    func percent(for address: BluetoothAddress) -> Int? { levels[address.string] }
}

@MainActor
struct BatteryTests {
    @Test func mapsUIDToPercentAndOmitsUnknown() {
        let hal = FakeHAL()
        hal.add(.init(uid: "AA-BB-CC-DD-EE-01:output", name: "JBL Grip"))
        hal.add(.init(uid: "AA-BB-CC-DD-EE-02:output", name: "JBL Grip"))
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let model = AppModel(
            hal: hal, defaults: defaults,
            battery: FakeBattery(levels: ["aa-bb-cc-dd-ee-01": 42]))
        model.catalog.start()
        model.refreshBatteryLevels()
        #expect(model.batteryPercent == ["AA-BB-CC-DD-EE-01:output": 42])
    }

    @Test func symbolFollowsLevel() {
        #expect(SpeakerCard.batterySymbol(10) == "battery.25")
        #expect(SpeakerCard.batterySymbol(50) == "battery.50")
        #expect(SpeakerCard.batterySymbol(75) == "battery.75")
        #expect(SpeakerCard.batterySymbol(100) == "battery.100")
    }
}
