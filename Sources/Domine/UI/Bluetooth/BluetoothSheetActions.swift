/// What the Bluetooth Speakers sheet can ask the model to do.
struct BluetoothSheetActions: Sendable {
    var connect: @MainActor @Sendable (BluetoothAddress) -> Void = { _ in }
    var disconnect: @MainActor @Sendable (BluetoothAddress) -> Void = { _ in }
    var pair: @MainActor @Sendable (BluetoothAddress) -> Void = { _ in }
    /// Removes the speaker from My Speakers only; macOS stays paired.
    var forget: @MainActor @Sendable (BluetoothAddress) -> Void = { _ in }
    var search: @MainActor @Sendable () -> Void = {}
    var stop: @MainActor @Sendable () -> Void = {}
    var done: @MainActor @Sendable () -> Void = {}

    static let none = BluetoothSheetActions()
}
