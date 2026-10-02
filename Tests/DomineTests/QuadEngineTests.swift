import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Quad routing through the engine against the fake HAL (SPEC 11).
@MainActor
final class QuadEngineTests {
    nonisolated static func grip(_ n: Int) -> FakeHAL.Device {
        FakeHAL.Device(uid: "60-FD-A6-19-00-0\(n):output", name: "JBL Grip", sampleRate: 44_100)
    }
    nonisolated static let grips = (1...4).map(grip)
    nonisolated static var uids: [String] { grips.map(\.uid) }

    let hal = FakeHAL()
    var engine: Engine!

    init() {
        engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero, fadeWait: { _ in })
        for grip in Self.grips { hal.add(grip) }
    }

    private var subDevices: [[String: Any]] {
        hal.lastAggregateDescription?[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []
    }

    private func render(output: [Int], frames: Int = 64) -> FakeBufferList {
        let input = FakeBufferList(channelsPerBuffer: [2], frames: frames)
        input.set(buffer: 0, channel: 0, Array(repeating: 0.5, count: frames))
        input.set(buffer: 0, channel: 1, Array(repeating: 0.25, count: frames))
        let out = FakeBufferList(channelsPerBuffer: output, frames: frames, fill: 9)
        hal.render(input: input, output: out)
        return out
    }

    @Test func aggregateHasFourSubDevicesWithFrontLeftAsClock() async {
        await engine.start(quad: Self.uids)
        #expect(engine.state == .running)
        let subs = subDevices
        #expect(subs.compactMap { $0[kAudioSubDeviceUIDKey] as? String } == Self.uids)
        #expect(subs[0][kAudioSubDeviceDriftCompensationKey] as? Int == 0)
        for sub in subs.dropFirst() {
            #expect(sub[kAudioSubDeviceDriftCompensationKey] as? Int == 1)
            #expect(sub[kAudioSubDeviceDriftCompensationQualityKey] as? Int == AggregateBuilder.driftQuality)
        }
        let description = hal.lastAggregateDescription
        #expect(description?[kAudioAggregateDeviceMainSubDeviceKey] as? String == Self.uids[0])
        #expect(description?[kAudioAggregateDeviceClockDeviceKey] as? String == Self.uids[0])
        #expect(description?[kAudioAggregateDeviceIsPrivateKey] as? Int == 1)
        // Never force a sample rate.
        #expect(!hal.ops.contains { if case .setSampleRate = $0 { true } else { false } })
    }

    @Test func offsetsFollowPositionOrder() async {
        await engine.start(quad: Self.uids)
        #expect(engine.layout?.outOffsets == [0, 2, 4, 6])
    }

    @Test func rendersEachPositionThroughTheCIOProc() async {
        await engine.start(quad: Self.uids)
        engine.rearTrim = 0.5
        let out = render(output: [2, 2, 2, 2])
        let front: [Float] = Array(repeating: 0.5, count: 64), frontR: [Float] = Array(repeating: 0.25, count: 64)
        #expect(out.channel(0) == front)
        #expect(out.channel(1) == front)
        #expect(out.channel(2) == frontR)
        #expect(out.channel(3) == frontR)
        #expect(out.channel(4).allSatisfy { $0 <= 0.25 + 1e-6 })
        #expect(out.channel(6).allSatisfy { $0 <= 0.125 + 1e-6 })
    }

    @Test func startAndStopTearDownInOrder() async {
        await engine.start(quad: Self.uids)
        #expect(hal.ops == [.createTap(excluding: [42]), .createAggregate, .createIOProc, .start])
        engine.stop()
        #expect(engine.state == .idle)
        #expect(Array(hal.ops.suffix(4)) == [.stop, .destroyIOProc, .destroyAggregate, .destroyTap])
        #expect(hal.liveTapCount == 0)
        #expect(hal.liveAggregateCount == 0)
        #expect(engine.quadUIDs == nil)
        #expect(!engine.isKernelAllocated)
    }

    @Test func refusesDuplicatesAndMissingDevices() async {
        await engine.start(quad: [Self.uids[0], Self.uids[1], Self.uids[2], Self.uids[2]])
        #expect(engine.state == .idle)
        #expect(engine.idleReason == .sameSpeaker)
        await engine.start(quad: [Self.uids[0], Self.uids[1], Self.uids[2], nil])
        #expect(engine.state == .idle)
        #expect(hal.liveAggregateCount == 0)
    }

    @Test func missingPositionRebuildsWithThree() async {
        await engine.start(quad: Self.uids)
        hal.remove(uid: Self.uids[3])
        await engine.speakerCheck?.value
        #expect(engine.state == .degraded(.quadFallback(missing: [3])))
        #expect(subDevices.compactMap { $0[kAudioSubDeviceUIDKey] as? String } == Array(Self.uids.prefix(3)))
        #expect(engine.layout?.outOffsets == [0, 2, 4, nil])
        #expect(hal.liveAggregateCount == 1)
        #expect(hal.liveTapCount == 1)

        // Front Right missing: the aggregate keeps position order for the rest.
        hal.add(Self.grips[3])
        await engine.speakerCheck?.value
        #expect(engine.state == .running)
        hal.remove(uid: Self.uids[1])
        await engine.speakerCheck?.value
        #expect(engine.layout?.outOffsets == [0, nil, 2, 4])
    }

    @Test func allGoneStops() async {
        var ended = 0
        engine.onRoutingEnded = { ended += 1 }
        await engine.start(quad: Self.uids)
        for uid in Self.uids { hal.remove(uid: uid) }
        await engine.speakerCheck?.value
        #expect(engine.state == .idle)
        #expect(engine.idleReason == .speakersDisconnected)
        #expect(ended == 1)
    }

    @Test func stereoStartStillBuildsTwoSubDevices() async {
        await engine.start(left: Self.uids[0], right: Self.uids[1])
        #expect(engine.state == .running)
        #expect(subDevices.count == 2)
        #expect(engine.layout?.outOffsets == [0, 2])
    }
}
