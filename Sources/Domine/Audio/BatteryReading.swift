/// Reads a Bluetooth speaker's battery level. Tests replace it with a fake.
protocol BatteryReading: Sendable {
    /// 1...100, or nil when the speaker does not report one.
    func percent(for address: BluetoothAddress) -> Int?
}
