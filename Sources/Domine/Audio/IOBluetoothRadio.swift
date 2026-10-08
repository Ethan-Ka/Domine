/// Placeholder until the IOBluetooth implementation lands. Reports nothing
/// and fails every action.
@MainActor
final class IOBluetoothRadio: BluetoothRadio {
    init() {}

    func pairedSpeakers() -> [BluetoothSpeaker] { [] }

    func startSearch(found: @escaping @MainActor (BluetoothSpeaker) -> Void,
                     finished: @escaping @MainActor () -> Void) {
        finished()
    }

    func stopSearch() {}
    func connect(_ address: BluetoothAddress) async -> Bool { false }
    func disconnect(_ address: BluetoothAddress) async -> Bool { false }
    func pair(_ address: BluetoothAddress) async -> Bool { false }
}
