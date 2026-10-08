import CoreAudio
import Foundation
import Testing
@testable import Domine

@MainActor
struct DropoutCountTests {
    static let a = FakeHAL.Device(uid: "60-FD-A6-19-4F-2A:output", name: "JBL Grip", availableSampleRates: [48_000...48_000])
    static let b = FakeHAL.Device(uid: "60-FD-A6-19-9C-11:output", name: "JBL Grip", availableSampleRates: [48_000...48_000])

    let hal = FakeHAL()
    let idA: AudioObjectID
    let idB: AudioObjectID
    let tracker: DropoutTracker

    init() {
        idA = hal.add(Self.a)
        idB = hal.add(Self.b)
        tracker = DropoutTracker(hal: hal, devices: [
            .init(label: "A", uid: Self.a.uid, id: idA),
            .init(label: "B", uid: Self.b.uid, id: idB),
        ])
        tracker.start()
    }

    @Test func overloadsCountPerSpeaker() {
        hal.fire(.processorOverload(idA))
        hal.fire(.processorOverload(idA))
        hal.fire(.processorOverload(idB))
        #expect(tracker.counts[uid: Self.a.uid].overloads == 2)
        #expect(tracker.counts[uid: Self.b.uid].overloads == 1)
    }

    @Test func removingADeviceCountsOneDisconnect() {
        hal.remove(uid: Self.b.uid)
        #expect(tracker.counts[uid: Self.b.uid].disconnects == 1)
        #expect(tracker.counts[uid: Self.a.uid].disconnects == 0)
    }

    @Test func reconnectThenRemoveCountsAgain() {
        hal.remove(uid: Self.a.uid)
        hal.add(Self.a)
        hal.remove(uid: Self.a.uid)
        #expect(tracker.counts[uid: Self.a.uid].disconnects == 2)
    }

    @Test func resetClearsCountsAndMovesSessionStart() {
        hal.fire(.processorOverload(idA))
        hal.remove(uid: Self.b.uid)
        let later = Date(timeIntervalSinceNow: 60)
        tracker.reset(at: later)
        #expect(tracker.counts.entries.isEmpty)
        #expect(tracker.counts.sessionStart == later)
    }

    @Test func stopRemovesListeners() {
        let before = hal.listenerCount
        tracker.stop()
        #expect(hal.listenerCount == before - 5)
    }
}
