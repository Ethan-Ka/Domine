import CoreAudio
import Foundation

/// Builds the description dictionary for Domine's private aggregate
/// (SPEC section 3.2). Device A is the main sub-device and clock; Device B,
/// when present, follows it with drift compensation on. The tap is the only
/// input and is drift compensated too.
enum AggregateBuilder {
    static let name = "Domine"

    static func uid(instance: UUID) -> String {
        DeviceCatalog.domineUIDPrefix + "aggregate." + instance.uuidString
    }

    static func description(
        uidA: String,
        uidB: String?,
        tapUID: String,
        instance: UUID = UUID()
    ) -> [String: Any] {
        var subDevices: [[String: Any]] = [
            [kAudioSubDeviceUIDKey: uidA, kAudioSubDeviceDriftCompensationKey: 0],
        ]
        if let uidB {
            subDevices.append([kAudioSubDeviceUIDKey: uidB, kAudioSubDeviceDriftCompensationKey: 1])
        }
        return [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid(instance: instance),
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: uidA,
            kAudioAggregateDeviceClockDeviceKey: uidA,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 1],
            ],
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
    }

    /// The capture permission probe's aggregate: private, the tap as its only
    /// member, no sub-devices, so no output device (and no Bluetooth device)
    /// is opened.
    static func probeDescription(tapUID: String, instance: UUID = UUID()) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: name + " Capture Check",
            kAudioAggregateDeviceUIDKey: DeviceCatalog.domineUIDPrefix + "capturecheck." + instance.uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 0],
            ],
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
    }
}
