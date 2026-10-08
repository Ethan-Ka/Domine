/// A Bluetooth speaker the user connected, paired, or assigned in Domine.
/// Kept across launches so My Speakers lists it even when it is off.
struct RememberedSpeaker: Codable, Equatable, Sendable {
    /// Lowercase, dash separated, as `BluetoothAddress.string`.
    var address: String
    var name: String
}
