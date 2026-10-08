import Dispatch
import IOBluetooth

/// Reconnects a paired speaker through IOBluetooth. The blocking
/// `openConnection()` call runs on a background queue, never the main actor.
struct IOBluetoothConnector: BluetoothConnecting {
    func connect(_ address: BluetoothAddress) async -> Bool {
        let text = address.string
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = IOBluetoothDevice(addressString: text)?.openConnection()
                continuation.resume(returning: status == kIOReturnSuccess)
            }
        }
    }
}
