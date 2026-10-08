import Foundation

/// The Bluetooth hardware address behind a Core Audio device UID.
///
/// Core Audio names classic Bluetooth outputs by address, e.g.
/// "AA-BB-CC-DD-EE-FF:output". `IOBluetoothDevice(addressString:)` wants
/// the same six bytes, so this is the bridge from a saved speaker UID to the
/// radio. Returns nil for any UID that does not start with an address.
struct BluetoothAddress: Hashable, Sendable, CustomStringConvertible {
    /// Lowercase, dash separated: "aa-bb-cc-dd-ee-ff".
    let string: String

    init?(deviceUID uid: String) {
        let head = uid.split(separator: ":", maxSplits: 1).first.map(String.init) ?? uid
        let parts = head.split(whereSeparator: { $0 == "-" || $0 == ":" })
        guard parts.count == 6,
              parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        string = parts.joined(separator: "-").lowercased()
    }

    var description: String { string }
}
