import CoreAudio
import Foundation
import Testing
@testable import Domine

struct AggregateBuilderTests {
    static let instance = UUID(uuidString: "00000000-0000-0000-0000-00000000ABCD")!
    static let aggregateUID = "com.ethankawley.Domine.aggregate.00000000-0000-0000-0000-00000000ABCD"

    @Test func stereoDescription() {
        let description = AggregateBuilder.description(
            uidA: "A:output", uidB: "B:output", tapUID: "TAP", instance: Self.instance)
        let expected: [String: Any] = [
            "name": "Domine",
            "uid": Self.aggregateUID,
            "private": 1,
            "stacked": 0,
            "master": "A:output",
            "clock": "A:output",
            "subdevices": [
                ["uid": "A:output", "drift": 0],
                ["uid": "B:output", "drift": 1, "drift quality": 0x7F],
            ],
            "taps": [["uid": "TAP", "drift": 1, "drift quality": 0x7F]],
            "tapautostart": 1,
        ]
        #expect(description as NSDictionary == expected as NSDictionary)
    }

    @Test func defaultClockIsLeftSpeaker() {
        #expect(AggregateBuilder.clock == .leftSpeaker)
        let description = AggregateBuilder.description(uidA: "A:output", uidB: "B:output", tapUID: "TAP")
        #expect(description["clock"] as? String == "A:output")
    }

    @Test func externalClockDriftCompensatesBothSpeakers() {
        let description = AggregateBuilder.description(
            uidA: "A:output", uidB: "B:output", tapUID: "TAP",
            clock: .device(uid: "com.ethankawley.Domine.VirtualOutput"), instance: Self.instance)
        #expect(description["master"] as? String == "A:output")
        #expect(description["clock"] as? String == "com.ethankawley.Domine.VirtualOutput")
        let subs = description["subdevices"] as? [[String: Any]]
        #expect(subs.map { $0 as NSArray } == [
            ["uid": "A:output", "drift": 1, "drift quality": 0x7F],
            ["uid": "B:output", "drift": 1, "drift quality": 0x7F],
        ] as NSArray)
    }

    @Test func clockMayBeDeviceB() {
        let description = AggregateBuilder.description(
            uidA: "A:output", uidB: "B:output", tapUID: "TAP", clock: .device(uid: "B:output"))
        let subs = description["subdevices"] as? [[String: Any]]
        #expect(subs.map { $0 as NSArray } == [
            ["uid": "A:output", "drift": 1, "drift quality": 0x7F],
            ["uid": "B:output", "drift": 0],
        ] as NSArray)
    }

    @Test func monoDescriptionHasOnlyA() {
        let description = AggregateBuilder.description(
            uidA: "A:output", uidB: nil, tapUID: "TAP", instance: Self.instance)
        let subs = description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
        #expect(subs.map { $0 as NSArray } == [["uid": "A:output", "drift": 0]] as NSArray)
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == "A:output")
        #expect(description[kAudioAggregateDeviceIsPrivateKey] as? Int == 1)
    }

    @Test func keysMatchCoreAudioConstants() {
        // Guards the literal keys above against a header change.
        #expect(kAudioAggregateDeviceMainSubDeviceKey == "master")
        #expect(kAudioAggregateDeviceClockDeviceKey == "clock")
        #expect(kAudioAggregateDeviceTapListKey == "taps")
        #expect(kAudioAggregateDeviceTapAutoStartKey == "tapautostart")
        #expect(kAudioSubDeviceDriftCompensationKey == "drift")
        #expect(kAudioSubTapDriftCompensationKey == "drift")
        #expect(kAudioSubTapUIDKey == "uid")
        #expect(kAudioSubDeviceDriftCompensationQualityKey == "drift quality")
        #expect(kAudioSubTapDriftCompensationQualityKey == "drift quality")
        #expect(kAudioAggregateDriftCompensationMaxQuality == 0x7F)
    }

    /// Every member that is drift compensated, under every clock choice,
    /// resamples at the highest quality, and the clock device is never
    /// resampled at all (SPEC section 4, Signal quality).
    @Test(arguments: [
        AggregateClock.leftSpeaker, .device(uid: "B:output"), .device(uid: "com.ethankawley.Domine.VirtualOutput"),
    ])
    func driftCompensationIsAlwaysMaxQuality(clock: AggregateClock) {
        #expect(AggregateBuilder.driftQuality == Int(kAudioAggregateDriftCompensationMaxQuality))
        let description = AggregateBuilder.description(uidA: "A:output", uidB: "B:output", tapUID: "TAP", clock: clock)
        let clockUID = description[kAudioAggregateDeviceClockDeviceKey] as? String
        let subs = description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []
        let taps = description[kAudioAggregateDeviceTapListKey] as? [[String: Any]] ?? []
        #expect(subs.count == 2)
        #expect(taps.count == 1)
        for sub in subs {
            let drift = sub[kAudioSubDeviceDriftCompensationKey] as? Int
            if sub[kAudioSubDeviceUIDKey] as? String == clockUID {
                #expect(drift == 0)
            } else {
                #expect(drift == 1)
                #expect(sub[kAudioSubDeviceDriftCompensationQualityKey] as? Int == 0x7F)
            }
        }
        for tap in taps {
            #expect(tap[kAudioSubTapDriftCompensationKey] as? Int == 1)
            #expect(tap[kAudioSubTapDriftCompensationQualityKey] as? Int == 0x7F)
        }
    }

    @Test func uidUsesDominePrefix() {
        #expect(AggregateBuilder.uid(instance: Self.instance).hasPrefix(DeviceCatalog.domineUIDPrefix))
    }
}

struct QuadAggregateTests {
    @Test func fourSubDevicesInOrder() throws {
        let uids = ["FL", "FR", "RL", "RR"]
        let d = AggregateBuilder.description(outputUIDs: uids, tapUID: "TAP", instance: UUID())
        let subs = try #require(d[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(subs.compactMap { $0[kAudioSubDeviceUIDKey] as? String } == uids)
        #expect(subs.map { $0[kAudioSubDeviceDriftCompensationKey] as? Int } == [0, 1, 1, 1])
        #expect(d[kAudioAggregateDeviceMainSubDeviceKey] as? String == "FL")
        #expect(d[kAudioAggregateDeviceClockDeviceKey] as? String == "FL")
        #expect(d[kAudioAggregateDeviceIsPrivateKey] as? Int == 1)
    }

    @Test func quadOffsets() throws {
        let layout = try AggregateLayout.compute(
            outputs: [[2], [1, 1], [2], [2]], subDeviceInputBuffers: 0,
            aggregateOutput: [2, 1, 1, 2, 2], aggregateInput: [2])
        #expect(layout.outOffsets == [0, 2, 4, 6])
    }

    @Test func missingRearKeepsOtherOffsets() throws {
        let layout = try AggregateLayout.compute(
            outputs: [[2], [2], nil, [2]], subDeviceInputBuffers: 0,
            aggregateOutput: [2, 2, 2], aggregateInput: [2])
        #expect(layout.outOffsets == [0, 2, nil, 4])
    }

    @Test func quadMismatchThrows() {
        #expect(throws: EngineError.self) {
            try AggregateLayout.compute(
                outputs: [[2], [2], [2], [2]], subDeviceInputBuffers: 0,
                aggregateOutput: [2, 2, 2], aggregateInput: [2])
        }
    }
}

struct AggregateLayoutTests {
    @Test func stereoSubDevices() throws {
        let layout = try AggregateLayout.compute(
            aOutput: [2], bOutput: [2], subDeviceInputBuffers: 0,
            aggregateOutput: [2, 2], aggregateInput: [2])
        #expect(layout == AggregateLayout(inFirstBuffer: 0, tapBuffers: 1, outAChannelOffset: 0, outBChannelOffset: 2))
    }

    @Test func monoStreams() throws {
        let layout = try AggregateLayout.compute(
            aOutput: [1, 1], bOutput: [1, 1], subDeviceInputBuffers: 0,
            aggregateOutput: [1, 1, 1, 1], aggregateInput: [2])
        #expect(layout.outBChannelOffset == 2)
    }

    @Test func unevenDevices() throws {
        let layout = try AggregateLayout.compute(
            aOutput: [1, 1, 1], bOutput: [2], subDeviceInputBuffers: 1,
            aggregateOutput: [1, 1, 1, 2], aggregateInput: [1, 2])
        #expect(layout == AggregateLayout(inFirstBuffer: 1, tapBuffers: 1, outAChannelOffset: 0, outBChannelOffset: 3))
    }

    @Test func noDeviceB() throws {
        let layout = try AggregateLayout.compute(
            aOutput: [2], bOutput: nil, subDeviceInputBuffers: 0,
            aggregateOutput: [2], aggregateInput: [2])
        #expect(layout.outBChannelOffset == nil)
    }

    @Test func outputMismatchThrows() {
        #expect(throws: EngineError.self) {
            try AggregateLayout.compute(
                aOutput: [2], bOutput: [2], subDeviceInputBuffers: 0,
                aggregateOutput: [2], aggregateInput: [2])
        }
    }

    @Test func missingTapThrows() {
        #expect(throws: EngineError.self) {
            try AggregateLayout.compute(
                aOutput: [2], bOutput: [2], subDeviceInputBuffers: 1,
                aggregateOutput: [2, 2], aggregateInput: [1])
        }
    }
}
