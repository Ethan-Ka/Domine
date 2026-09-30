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
}
