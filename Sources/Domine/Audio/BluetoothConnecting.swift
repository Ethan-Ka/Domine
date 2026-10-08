/// Opens a baseband connection to a paired Bluetooth speaker.
protocol BluetoothConnecting: Sendable {
    /// True when the connection opened.
    func connect(_ address: BluetoothAddress) async -> Bool
}
