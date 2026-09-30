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
                ["uid": "B:output", "drift": 1],
            ],
            "taps": [["uid": "TAP", "drift": 1]],
            "tapautostart": 1,
        ]
        #expect(description as NSDictionary == expected as NSDictionary)
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
    }

    @Test func uidUsesDominePrefix() {
        #expect(AggregateBuilder.uid(instance: Self.instance).hasPrefix(DeviceCatalog.domineUIDPrefix))
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
