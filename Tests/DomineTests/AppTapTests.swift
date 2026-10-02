import CoreAudio
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

    @Test func capsAtSevenAppTaps() async {
        let requests = (0..<10).map { AppTapRequest(key: "com.app\($0)", processes: [AudioObjectID(10 + $0)], gain: 0.5) }
        let engine = await startedEngine(requests)
        #expect(appTaps() == 7)
        engine.stop()
    }
}
