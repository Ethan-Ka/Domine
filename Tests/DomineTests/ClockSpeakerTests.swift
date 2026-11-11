import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Timing reference (Settings > Advanced): the chosen speaker clocks the aggregate.
@MainActor
struct ClockSpeakerTests {
    let hal = FakeHAL()
    let engine: Engine
    static let a = EngineTests.gripA
    static let b = EngineTests.gripB

    init() {
        engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero, fadeWait: { _ in })
    }

    private var clockUID: String? {
        hal.lastAggregateDescription?[kAudioAggregateDeviceClockDeviceKey] as? String
    }

    private var aggregateCount: Int { hal.ops.filter { $0 == .createAggregate }.count }

    private func drift() throws -> [Int?] {
        let subs = try #require(hal.lastAggregateDescription?[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        return subs.map { $0[kAudioSubDeviceDriftCompensationKey] as? Int }
    }

    private func start() async {
        hal.add(Self.a)
        hal.add(Self.b)
        await engine.start(left: Self.a.uid, right: Self.b.uid)
    }

    @Test func defaultIsTheFirstSpeaker() async throws {
        await start()
        #expect(clockUID == Self.a.uid)
        #expect(try drift() == [0, 1])
    }

    @Test func chosenSpeakerIsPassedToTheDescription() async throws {
        engine.clockSpeakerUID = Self.b.uid
        await start()
        #expect(clockUID == Self.b.uid)
        let description = try #require(hal.lastAggregateDescription)
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == Self.a.uid)
        #expect(try drift() == [1, 0])
    }

    @Test func speakerNotInTheRouteFallsBackToTheFirst() async {
        engine.clockSpeakerUID = "AA-BB-CC-DD-EE-FF:output"
        await start()
        #expect(clockUID == Self.a.uid)
    }

    @Test func changingWhileRoutingRebuildsOnce() async {
        await start()
        #expect(aggregateCount == 1)
        await engine.setClockSpeaker(Self.b.uid)
        #expect(engine.state == .running)
        #expect(aggregateCount == 2)
        #expect(clockUID == Self.b.uid)
        // The same choice again does nothing.
        await engine.setClockSpeaker(Self.b.uid)
        #expect(aggregateCount == 2)
    }

    @Test func changeThatKeepsTheSameClockDoesNotRebuild() async {
        await start()
        await engine.setClockSpeaker(Self.a.uid)
        #expect(aggregateCount == 1)
        await engine.setClockSpeaker("AA-BB-CC-DD-EE-FF:output")
        #expect(aggregateCount == 1)
    }

    @Test func changingWhileIdleOnlyStoresIt() async {
        await engine.setClockSpeaker(Self.b.uid)
        #expect(aggregateCount == 0)
        await start()
        #expect(clockUID == Self.b.uid)
    }

    @Test func surroundUsesTheChosenSpeaker() async {
        let c = FakeHAL.Device(uid: "60-FD-A6-19-77-01:output", name: "JBL Grip", sampleRate: 44_100)
        hal.add(Self.a)
        hal.add(Self.b)
        hal.add(c)
        engine.clockSpeakerUID = c.uid
        await engine.start(surround: [
            SurroundSpeaker(uid: Self.a.uid, azimuth: -30),
            SurroundSpeaker(uid: Self.b.uid, azimuth: 30),
            SurroundSpeaker(uid: c.uid, azimuth: 180),
        ])
        #expect(engine.state.isRouting)
        #expect(clockUID == c.uid)
    }
}
