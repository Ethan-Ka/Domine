import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Surround routing and the demo through the engine against the fake HAL
/// (SPEC 13.2, 13.4, 13.5, 14.4).
@MainActor
final class SurroundEngineTests {
    nonisolated static func device(_ n: Int) -> FakeHAL.Device {
        FakeHAL.Device(uid: String(format: "60-FD-A6-19-00-%02X:output", n), name: "JBL Grip", sampleRate: 44_100)
    }
    nonisolated static let devices = (1...16).map(device)

    let hal = FakeHAL()
    var engine: Engine!

    init() {
        engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero, fadeWait: { _ in })
        for device in Self.devices { hal.add(device) }
    }

    private func speakers(_ count: Int) -> [SurroundSpeaker] {
        (0..<count).map { SurroundSpeaker(uid: Self.devices[$0].uid, azimuth: SurroundSpeaker.defaultAzimuth(forIndex: $0)) }
    }

    private var subDeviceUIDs: [String] {
        (hal.lastAggregateDescription?[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? [])
            .compactMap { $0[kAudioSubDeviceUIDKey] as? String }
    }

    private var aggregateCount: Int { hal.ops.filter { $0 == .createAggregate }.count }

    @Test(arguments: [3, 5, 16])
    func aggregateHoldsEverySpeakerInListOrder(count: Int) async {
        let set = speakers(count)
        await engine.start(surround: set)
        #expect(engine.state == .running)
        #expect(subDeviceUIDs == set.map(\.uid))
        let description = hal.lastAggregateDescription
        #expect(description?[kAudioAggregateDeviceClockDeviceKey] as? String == set[0].uid)
        #expect(description?[kAudioAggregateDeviceMainSubDeviceKey] as? String == set[0].uid)
        #expect(description?[kAudioAggregateDeviceIsPrivateKey] as? Int == 1)
        let subs = description?[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []
        let drift: [Int] = subs.map { $0[kAudioSubDeviceDriftCompensationKey] as? Int ?? -1 }
        #expect(drift == [0] + Array(repeating: 1, count: count - 1))
        #expect(engine.layout?.outOffsets == (0..<count).map { Optional($0 * 2) })
        #expect(engine.pushedSurround?.azimuths == set.map(\.azimuth))
        #expect(engine.surroundPeaks().count == count)
        #expect(engine.isKernelAllocated)
        #expect(!hal.ops.contains { if case .setSampleRate = $0 { true } else { false } })
    }

    @Test func refusesEmptyDuplicateAndAllMissing() async {
        await engine.start(surround: [])
        #expect(engine.idleReason == .noSurroundSpeakers)
        let set = speakers(3)
        await engine.start(surround: [set[0], set[1], set[1]])
        #expect(engine.idleReason == .sameSpeaker)
        await engine.start(surround: [SurroundSpeaker(uid: "gone-1", azimuth: 0), SurroundSpeaker(uid: "gone-2", azimuth: 90)])
        #expect(engine.idleReason == .surroundMissing)
        #expect(engine.state == .idle)
        #expect(hal.liveAggregateCount == 0)
    }

    @Test func missingSpeakerRebuildsWithTheRestAndReturns() async {
        let set = speakers(4)
        await engine.start(surround: set)
        hal.remove(uid: set[1].uid)
        await engine.speakerCheck?.value
        #expect(engine.state == .degraded(.quadFallback(missing: [set[1].uid])))
        #expect(subDeviceUIDs == [set[0].uid, set[2].uid, set[3].uid])
        #expect(engine.layout?.outOffsets == [0, nil, 2, 4])
        // The kernel keeps the full layout; VBAP re-pans the missing share.
        #expect(engine.pushedSurround?.azimuths.count == 4)
        #expect(hal.liveAggregateCount == 1)
        #expect(hal.liveTapCount == 1)

        // The clock speaker going makes the next present one the clock.
        hal.remove(uid: set[0].uid)
        await engine.speakerCheck?.value
        #expect(hal.lastAggregateDescription?[kAudioAggregateDeviceClockDeviceKey] as? String == set[2].uid)

        hal.add(Self.devices[0])
        hal.add(Self.devices[1])
        await engine.speakerCheck?.value
        #expect(engine.state == .running)
        #expect(subDeviceUIDs == set.map(\.uid))
    }

    @Test func oneLeftPlaysTheMonoSum() async {
        let set = speakers(3)
        await engine.start(surround: set)
        hal.remove(uid: set[1].uid)
        hal.remove(uid: set[2].uid)
        await engine.speakerCheck?.value
        #expect(engine.state == .degraded(.quadFallback(missing: [set[1].uid, set[2].uid])))
        #expect(engine.layout?.outOffsets == [0, nil, nil])
        let frames = 64
        let input = FakeBufferList(channelsPerBuffer: [2], frames: frames)
        input.set(buffer: 0, channel: 0, Array(repeating: 0.5, count: frames))
        input.set(buffer: 0, channel: 1, Array(repeating: 0.25, count: frames))
        var out = FakeBufferList(channelsPerBuffer: [2], frames: frames, fill: 9)
        // The rebuild fades in over 50 ms; render past it.
        for _ in 0..<80 {
            out = FakeBufferList(channelsPerBuffer: [2], frames: frames, fill: 9)
            hal.render(input: input, output: out)
        }
        #expect(out.channel(0).allSatisfy { abs($0 - 0.375) < 1e-6 })
        #expect(out.channel(1).allSatisfy { abs($0 - 0.375) < 1e-6 })
    }

    @Test func allGoneStops() async {
        var ended = 0
        engine.onRoutingEnded = { ended += 1 }
        let set = speakers(3)
        await engine.start(surround: set)
        for speaker in set { hal.remove(uid: speaker.uid) }
        await engine.speakerCheck?.value
        #expect(engine.state == .idle)
        #expect(engine.idleReason == .speakersDisconnected)
        #expect(ended == 1)
        #expect(hal.liveAggregateCount == 0)
    }

    @Test func stopTearsDownInOrder() async {
        await engine.start(surround: speakers(3))
        #expect(hal.ops == [.createTap(excluding: [42]), .createAggregate, .createIOProc, .start])
        engine.stop()
        #expect(engine.state == .idle)
        #expect(Array(hal.ops.suffix(4)) == [.stop, .destroyIOProc, .destroyAggregate, .destroyTap])
        #expect(engine.surroundRoute == nil)
        #expect(!engine.isKernelAllocated)
    }

    /// SPEC 13.4: 2 m and 3 m give 2.915 ms and 0.667 on the near one;
    /// calibration offsets add and the smallest total is subtracted.
    @Test func distanceCompensationCombinesWithTrimAndOffsets() async throws {
        var set = speakers(3)
        set[0].distance = 2
        set[1].distance = 3
        set[2].distance = 3
        await engine.start(surround: set)
        engine.surroundGains = [set[0].uid: 0.5]
        var pushed = try #require(engine.pushedSurround)
        #expect(abs(pushed.delaysMs[0] - 2.9154519) < 1e-3)
        #expect(pushed.delaysMs[1] == 0 && pushed.delaysMs[2] == 0)
        #expect(abs(pushed.gains[0] - 0.5 * 2 / 3) < 1e-5)
        #expect(pushed.gains[1] == 1)

        engine.surroundDelaysMs = [set[1].uid: 10, set[2].uid: 4]
        pushed = try #require(engine.pushedSurround)
        // Totals 2.915, 10, 4; the smallest (2.915) becomes 0.
        #expect(pushed.delaysMs[0] == 0)
        #expect(abs(pushed.delaysMs[1] - (10 - 2.9154519)) < 1e-3)
        #expect(abs(pushed.delaysMs[2] - (4 - 2.9154519)) < 1e-3)
    }

    @Test func movingASpeakerIsLiveWithoutARebuild() async {
        var set = speakers(3)
        await engine.start(surround: set)
        let built = aggregateCount
        set[2].azimuth = 150
        engine.surroundSpeakers = set
        #expect(engine.pushedSurround?.azimuths == [-30, 30, 150])
        #expect(aggregateCount == built)
    }

    @Test func surroundDemoZeroesRotationAndOrbitThenRestores() async {
        await engine.start(surround: speakers(3))
        engine.rotation = 45
        engine.orbitRate = 20
        await engine.setDemo(true)
        #expect(engine.demoRequested)
        #expect(engine.pushedSurround?.rotation == 0)
        #expect(engine.pushedSurround?.orbitRate == 0)
        await engine.setDemo(false)
        #expect(!engine.demoRequested)
        #expect(engine.pushedSurround?.rotation == 45)
        #expect(engine.pushedSurround?.orbitRate == 20)
    }

    @Test func stereoDemoRebuildsOnTheSurroundKernelAndBack() async {
        let (a, b) = (Self.devices[0].uid, Self.devices[1].uid)
        await engine.start(left: a, right: b)
        #expect(engine.kernelSampleRate != nil)
        await engine.setDemo(true)
        #expect(engine.stereoDemo)
        #expect(engine.demoRequested)
        #expect(engine.kernelSampleRate != nil)
        #expect(engine.pushedSurround?.azimuths == [-30, 30])
        #expect(subDeviceUIDs == [a, b])
        #expect(engine.state == .running)

        await engine.setDemo(false)
        #expect(!engine.stereoDemo)
        #expect(!engine.demoRequested)
        #expect(engine.kernelSampleRate != nil)
        #expect(hal.liveAggregateCount == 1)
        #expect(hal.liveTapCount == 1)
    }

    @Test func stereoDemoAppliesSwap() async {
        await engine.start(left: Self.devices[0].uid, right: Self.devices[1].uid)
        engine.swapSides = true
        await engine.setDemo(true)
        #expect(engine.pushedSurround?.azimuths == [30, -30])
    }

    @Test func deviceRemovalDuringStereoDemoStopsIt() async {
        let (a, b) = (Self.devices[0].uid, Self.devices[1].uid)
        await engine.start(left: a, right: b)
        await engine.setDemo(true)
        hal.remove(uid: b)
        await engine.speakerCheck?.value
        #expect(engine.state == .degraded(.monoFallback(missing: .right)))
        #expect(!engine.stereoDemo)
        #expect(!engine.demoRequested)
        #expect(engine.kernelSampleRate != nil)
    }

    @Test func demoNeedsRouting() async {
        await engine.setDemo(true)
        #expect(!engine.demoRequested)
        #expect(engine.demoStatus().playing == false)
    }
}
