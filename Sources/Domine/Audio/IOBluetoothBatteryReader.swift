import Foundation
import IOBluetooth

/// Battery level from IOBluetooth's key-value properties. These are not
/// public API, so each key is checked before use and nil means unknown.
struct IOBluetoothBatteryReader: BatteryReading {
    private static let keys = ["batteryPercentSingle", "batteryPercentCombined"]

    func percent(for address: BluetoothAddress) -> Int? {
        guard let device = IOBluetoothDevice(addressString: address.string) else { return nil }
        for key in Self.keys {
            guard device.responds(to: NSSelectorFromString(key)),
                  let value = device.value(forKey: key) as? NSNumber else { continue }
            let percent = value.intValue
            if (1...100).contains(percent) { return percent }
        }
        return nil
    }
}
