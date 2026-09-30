import CoreAudio

/// An output device as the catalog last saw it. `uid` is the identity;
/// `id` is only valid until the device reconnects.
struct OutputDevice: Identifiable, Equatable, Sendable {
    let uid: String
    let id: AudioObjectID
    let name: String
    let outputChannels: Int
    let transportType: UInt32

    var isBluetooth: Bool {
        Self.isBluetooth(transportType: transportType)
    }

    static func isBluetooth(transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Four characters that tell two identically named devices apart, e.g. "5BB0"
    /// for "60-FD-A6-19-5B-B0:output".
    var uidSuffix: String {
        Self.suffix(forUID: uid)
    }

    static func suffix(forUID uid: String) -> String {
        let base = uid.split(separator: ":").first.map(String.init) ?? uid
        let alphanumerics = base.filter { $0.isLetter || $0.isNumber }
        return String(alphanumerics.suffix(4)).uppercased()
    }
}
