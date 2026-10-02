import CoreAudio
import Foundation

/// Builds the description dictionary for Domine's private aggregate
/// (SPEC section 3.2). Device A is the main sub-device. The clock comes from
/// `clock`; every sub-device that does not provide the clock, and the tap,
/// is drift compensated at `driftQuality`.
enum AggregateBuilder {
    static let name = "Domine"

    /// The clock used for every aggregate the engine builds. Change it here.
    static let clock: AggregateClock = .leftSpeaker
    /// Resampler quality for drift compensation.
    static let driftQuality = Int(kAudioAggregateDriftCompensationMaxQuality)

    static func uid(instance: UUID) -> String {
        DeviceCatalog.domineUIDPrefix + "aggregate." + instance.uuidString
    }

    static func description(
        uidA: String,
        uidB: String?,
        tapUID: String,
        clock: AggregateClock = clock,
        instance: UUID = UUID()
    ) -> [String: Any] {
        description(
            outputUIDs: [uidA] + (uidB.map { [$0] } ?? []),
            tapUID: tapUID, clock: clock, instance: instance)
    }

    /// N output sub-devices in position order (SPEC 11.1). The first is the
    /// main sub-device. With `.leftSpeaker` it is also the clock; the rest,
    /// and the tap, are drift compensated. No sample rate is ever set.
    static func description(
        outputUIDs: [String],
        tapUID: String,
        appTapUIDs: [String] = [],
        clock: AggregateClock = clock,
        instance: UUID = UUID()
    ) -> [String: Any] {
        precondition(!outputUIDs.isEmpty, "aggregate needs at least one output")
        let uidA = outputUIDs[0]
        let clockUID: String = switch clock {
        case .leftSpeaker: uidA
        case .device(let uid): uid
        }
        func subDevice(_ uid: String) -> [String: Any] {
            uid == clockUID
                ? [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: 0]
                : [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: 1,
                   kAudioSubDeviceDriftCompensationQualityKey: driftQuality]
        }
        let subDevices = outputUIDs.map(subDevice)
        return [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid(instance: instance),
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: uidA,
            kAudioAggregateDeviceClockDeviceKey: clockUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: ([tapUID] + appTapUIDs).map { uid in
                [kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: 1,
                 kAudioSubTapDriftCompensationQualityKey: driftQuality] as [String: Any]
            },
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
