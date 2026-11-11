import Foundation
import IOBluetooth

/// Battery level from IOBluetooth's key-value properties. These are not
/// public API, so each key is checked before use and nil means unknown.
struct IOBluetoothBatteryReader: BatteryReading {
    private static let keys = ["batteryPercentSingle", "batteryPercentCombined"]
    /// Unverified names for a charging flag; absent on most devices.
    private static let chargingKeys = ["isCharging", "batteryCharging", "batteryIsCharging"]

    /// 1...100 from a KVC value, else nil.
    static func parsePercent(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let percent = number.intValue
        return (1...100).contains(percent) ? percent : nil
    }

    /// A boolean KVC value, else nil.
    static func parseCharging(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    func percent(for address: BluetoothAddress) -> Int? {
        guard let device = IOBluetoothDevice(addressString: address.string) else { return nil }
        for key in Self.keys {
            guard device.responds(to: NSSelectorFromString(key)),
                  let percent = Self.parsePercent(device.value(forKey: key)) else { continue }
            return percent
        }
        return nil
    }

    func isCharging(for address: BluetoothAddress) -> Bool? {
        guard let device = IOBluetoothDevice(addressString: address.string) else { return nil }
        for key in Self.chargingKeys {
            guard device.responds(to: NSSelectorFromString(key)),
                  let charging = Self.parseCharging(device.value(forKey: key)) else { continue }
            return charging
        }
        return nil
    }
}
