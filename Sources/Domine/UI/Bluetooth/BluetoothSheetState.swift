/// What the Bluetooth Speakers sheet shows.
struct BluetoothSheetState: Equatable, Sendable {
    var mySpeakers: [BluetoothSheetRow] = []
    var otherPaired: [BluetoothSheetRow] = []
    var nearby: [BluetoothSheetRow] = []
    var isSearching = false
    /// True once a search has run, so an empty Nearby list can say so.
    var hasSearched = false
    var error: String?
}

/// One speaker row. Name and suffix stay separate views.
struct BluetoothSheetRow: Identifiable, Equatable, Sendable {
    var address: BluetoothAddress
    var name: String
    var isConnected: Bool
    var isBusy: Bool

    var id: String { address.string }
    var suffix: String { OutputDevice.suffix(forUID: address.string) }
}
