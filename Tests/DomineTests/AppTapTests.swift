import CoreAudio
import DomineDSP
import Foundation
import Testing
@testable import Domine

@MainActor
struct AppTapTests {
    static let gripA = FakeHAL.Device(uid: "60-FD-A6-19-4F-2A:output", name: "JBL Grip", sampleRate: 44_100)
    static let gripB = FakeHAL.Device(uid: "60-FD-A6-19-9C-11:output", name: "JBL Grip", sampleRate: 44_100)

    let hal = FakeHAL()

    private func count(_ match: (FakeHAL.Op) -> Bool) -> Int { hal.ops.filter(match).count }
    private func appTaps() -> Int { count { if case .createAppTap = $0 { true } else { false } } }
    private func aggregates() -> Int { count { $0 == .createAggregate } }

    private func startedEngine(_ requests: [AppTapRequest]) async -> Engine {
        let engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero)
        engine.appTapDebounce = .zero
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        engine.setAppTaps(requests)
        await engine.start(left: Self.gripA.uid, right: Self.gripB.uid)
        return engine
    }

    @Test func eachReducedAppGetsATapAndTheGlobalTapExcludesIt() async {
        let engine = await startedEngine([
            AppTapRequest(key: "com.a", processes: [7, 8], gain: 0.5),
            AppTapRequest(key: "com.b", processes: [9], gain: 0.25),
        ])
        #expect(engine.state == .running)
        #expect(hal.ops.contains(.createTap(excluding: [42, 7, 8, 9])))
        #expect(hal.ops.contains(.createAppTap(processes: [7, 8])))
        #expect(hal.ops.contains(.createAppTap(processes: [9])))
        #expect(hal.liveTapCount == 3)
        engine.stop()
        #expect(hal.liveTapCount == 0)
    }

    @Test func volumeChangeDoesNotRebuild() async {
        let engine = await startedEngine([AppTapRequest(key: "com.a", processes: [7], gain: 0.5)])
        let built = aggregates()
        engine.setAppTaps([AppTapRequest(key: "com.a", processes: [7], gain: 0.2)])
        await engine.appTapRebuild?.value
        #expect(aggregates() == built)
        #expect(appTaps() == 1)
        engine.stop()
    }

    @Test func changingTheSetRebuilds() async {
        let engine = await startedEngine([AppTapRequest(key: "com.a", processes: [7], gain: 0.5)])
        let built = aggregates()
        engine.setAppTaps([
            AppTapRequest(key: "com.a", processes: [7], gain: 0.5),
            AppTapRequest(key: "com.b", processes: [9], gain: 0.5),
        ])
        await engine.appTapRebuild?.value
        #expect(aggregates() == built + 1)
        #expect(hal.ops.contains(.createAppTap(processes: [9])))
        #expect(engine.state == .running)
        engine.stop()
    }

    @Test func restartWithinTheDebounceDoesNotRebuildAgain() async {
        let engine = await startedEngine([AppTapRequest(key: "com.a", processes: [7], gain: 0.5)])
        engine.appTapDebounce = .milliseconds(200)
        let built = aggregates()
        engine.setAppTaps([
            AppTapRequest(key: "com.a", processes: [7], gain: 0.5),
            AppTapRequest(key: "com.b", processes: [9], gain: 0.5),
        ])
        engine.stop()
        await engine.start(left: Self.gripA.uid, right: Self.gripB.uid)
        #expect(aggregates() == built + 1)
        await engine.appTapRebuild?.value
        // The restart already built the new set of taps.
        #expect(aggregates() == built + 1)
        #expect(engine.state == .running)
        engine.stop()
    }

    @Test func capsAtSevenAppTaps() async {
        let requests = (0..<10).map { AppTapRequest(key: "com.app\($0)", processes: [AudioObjectID(10 + $0)], gain: 0.5) }
        let engine = await startedEngine(requests)
        #expect(appTaps() == 7)
        engine.stop()
    }

    // MARK: - Helper processes update the taps in place

    private func appTapUpdates() -> [[AudioObjectID]] {
        hal.ops.compactMap { if case .setAppTapProcesses(_, let p) = $0 { p } else { nil } }
    }

    @Test func helperStartingUpdatesTheAppTapInPlace() async {
        let engine = await startedEngine([
            AppTapRequest(key: "com.a", processes: [7], gain: 0.5),
            AppTapRequest(key: "com.b", processes: [9], gain: 0.25),
        ])
        let built = aggregates()
        engine.setAppTaps([
            AppTapRequest(key: "com.a", processes: [7, 8], gain: 0.5),
            AppTapRequest(key: "com.b", processes: [9], gain: 0.25),
        ])
        await engine.appTapRebuild?.value
        #expect(appTapUpdates() == [[7, 8]])
        #expect(hal.ops.last == .setTapExclusions(excluding: [42, 7, 8, 9]))
        #expect(aggregates() == built)
        #expect(appTaps() == 2)
        #expect(engine.state == .running)
        engine.stop()
        #expect(hal.liveTapCount == 0)
    }

    @Test func helperQuittingUpdatesTheAppTapInPlace() async {
        let engine = await startedEngine([AppTapRequest(key: "com.a", processes: [7, 8], gain: 0.5)])
        let built = aggregates()
        engine.setAppTaps([AppTapRequest(key: "com.a", processes: [7], gain: 0.5)])
        await engine.appTapRebuild?.value
        #expect(appTapUpdates() == [[7]])
        #expect(hal.ops.last == .setTapExclusions(excluding: [42, 7]))
        #expect(aggregates() == built)
        // The same lists again change nothing.
        let ops = hal.ops.count
        engine.setAppTaps([AppTapRequest(key: "com.a", processes: [7], gain: 0.5)])
        #expect(hal.ops.count == ops)
        engine.stop()
    }

    @Test func failedInPlaceUpdateRebuilds() async {
        let engine = await startedEngine([AppTapRequest(key: "com.a", processes: [7], gain: 0.5)])
        let built = aggregates()
        hal.failures[.setAppTapProcesses] = kAudioHardwareUnspecifiedError
        engine.setAppTaps([AppTapRequest(key: "com.a", processes: [7, 8], gain: 0.5)])
        await engine.appTapRebuild?.value
        #expect(aggregates() == built + 1)
        #expect(hal.ops.contains(.createAppTap(processes: [7, 8])))
        #expect(hal.ops.contains(.createTap(excluding: [42, 7, 8])))
        #expect(engine.state == .running)
        engine.stop()
    }

    @Test func failedExclusionUpdateRebuilds() async {
        let engine = await startedEngine([AppTapRequest(key: "com.a", processes: [7], gain: 0.5)])
        let built = aggregates()
        hal.failures[.setTapExclusions] = kAudioHardwareUnspecifiedError
        engine.setAppTaps([AppTapRequest(key: "com.a", processes: [7, 8], gain: 0.5)])
        await engine.appTapRebuild?.value
        #expect(aggregates() == built + 1)
        #expect(hal.ops.contains(.createTap(excluding: [42, 7, 8])))
        engine.stop()
    }

    // MARK: - Changes while starting

    private func slowStart(_ requests: [AppTapRequest]) async -> (Engine, Task<Void, Never>) {
        let engine = Engine(hal: hal, layoutAttempts: 50, layoutRetryDelay: .milliseconds(5))
        engine.appTapDebounce = .zero
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        hal.aggregateStreamsHiddenForAttempts = 3
        engine.setAppTaps(requests)
        let task = Task { await engine.start(left: Self.gripA.uid, right: Self.gripB.uid) }
        // The taps and aggregate exist; the build waits for the streams.
        while engine.state != .starting || hal.liveAggregateCount == 0 { await Task.yield() }
        return (engine, task)
    }

    @Test func processChangeWhileStartingIsAppliedInPlace() async {
        let (engine, task) = await slowStart([AppTapRequest(key: "com.a", processes: [7], gain: 0.5)])
        engine.setAppTaps([AppTapRequest(key: "com.a", processes: [7, 8], gain: 0.5)])
        await task.value
        await engine.appTapRebuild?.value
        #expect(engine.state == .running)
        #expect(appTapUpdates() == [[7, 8]])
        #expect(hal.ops.last == .setTapExclusions(excluding: [42, 7, 8]))
        #expect(aggregates() == 1)
        engine.stop()
    }

    @Test func newAppWhileStartingRebuildsAfterTheStart() async {
        let (engine, task) = await slowStart([AppTapRequest(key: "com.a", processes: [7], gain: 0.5)])
        engine.setAppTaps([
            AppTapRequest(key: "com.a", processes: [7], gain: 0.5),
            AppTapRequest(key: "com.b", processes: [9], gain: 0.5),
        ])
        await task.value
        await engine.appTapRebuild?.value
        #expect(engine.state == .running)
        #expect(aggregates() == 2)
        #expect(hal.ops.contains(.createAppTap(processes: [9])))
        #expect(hal.liveTapCount == 3)
        engine.stop()
    }

    // MARK: - Boost

    @Test func gainAboveOneGetsATapAndKeepsItsValue() async {
        let engine = await startedEngine([AppTapRequest(key: "com.a", processes: [7], gain: 2)])
        #expect(hal.ops.contains(.createAppTap(processes: [7])))
        #expect(engine.appTapRequests.first?.gain == 2)
        engine.stop()
    }

    @Test func maxAppTapsMatchesTheKernelLimit() {
        #expect(Engine.maxAppTaps == Int(DOMINE_MAX_TAPS) - 1)
        #expect(Engine.maxAppTaps == 7)
    }
}
