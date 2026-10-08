/// A Bluetooth audio device as Domine's Bluetooth window shows it.
struct BluetoothSpeaker: Identifiable, Equatable, Sendable {
    let address: BluetoothAddress
    var name: String
    var isPaired: Bool
    var isConnected: Bool

    var id: String { address.string }
}

/// Finds, pairs, connects and disconnects Bluetooth audio devices, so the
/// user never has to open System Settings > Bluetooth. Only audio devices
/// (speakers, headphones) are reported. The real one wraps IOBluetooth;
/// tests use a fake.
@MainActor
protocol BluetoothRadio: AnyObject {
    /// Paired audio devices, connected or not.
    func pairedSpeakers() -> [BluetoothSpeaker]

    /// Searches for unpaired audio devices in pairing mode. `found` is called
    /// on the main actor for each new device; `finished` once the search ends
    /// (about 10 s) or is stopped.
    func startSearch(found: @escaping @MainActor (BluetoothSpeaker) -> Void,
                     finished: @escaping @MainActor () -> Void)
    func stopSearch()

    /// Each returns true on success.
    func connect(_ address: BluetoothAddress) async -> Bool
    func disconnect(_ address: BluetoothAddress) async -> Bool
    /// Pairs an unpaired device, then connects it.
    func pair(_ address: BluetoothAddress) async -> Bool
}
