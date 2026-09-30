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

    /// Short connection name for lists, e.g. "Bluetooth" or "USB".
    var transportName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeBuiltIn: "Built-in"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypeFireWire: "FireWire"
        case kAudioDeviceTransportTypePCI: "PCI"
        case kAudioDeviceTransportTypeAVB: "AVB"
        case kAudioDeviceTransportTypeVirtual: "Virtual"
        case kAudioDeviceTransportTypeAggregate: "Aggregate"
        default: "Audio output"
        }
    }

    /// Four characters that tell two identically named devices apart, e.g. "5BB0"
    /// for "60-FD-A6-19-5B-B0:output".
    var uidSuffix: String {
        Self.suffix(forUID: uid)
    }

    /// Single-string label for menus and pickers, which cannot style parts
    /// separately: "JBL Grip (4F2A)". Elsewhere show name and suffix as two views.
    var menuLabel: String {
        Self.menuLabel(name: name, uid: uid)
    }

    static func menuLabel(name: String, uid: String) -> String {
        "\(name) (\(suffix(forUID: uid)))"
    }

    /// The last four hex digits of a Bluetooth address, or four hex digits of a
    /// stable hash for UIDs that are not addresses ("BuiltInSpeakerDevice").
    static func suffix(forUID uid: String) -> String {
        let base = uid.split(separator: ":").first.map(String.init) ?? uid
        let hex = base.filter { $0 != "-" }
        if hex.count == 12, hex.allSatisfy(\.isHexDigit) {
            return String(hex.suffix(4)).uppercased()
        }
        // FNV-1a, folded to 16 bits. Stable across launches, unlike hashValue.
        var hash: UInt32 = 2_166_136_261
        for byte in uid.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(format: "%04X", (hash >> 16) ^ (hash & 0xFFFF))
    }
}
