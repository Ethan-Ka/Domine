import CoreAudio
import Foundation
import Testing
@testable import Domine

@MainActor
struct ExclusionTests {
    static let gripA = FakeHAL.Device(uid: "60-FD-A6-19-4F-2A:output", name: "JBL Grip", sampleRate: 44_100)
    static let gripB = FakeHAL.Device(uid: "60-FD-A6-19-9C-11:output", name: "JBL Grip", sampleRate: 44_100)

    let hal = FakeHAL()
    /// Debounce waits are released by hand so tests need no real time.
    let gate = Gate()

    final class Gate {
        var waiters: [CheckedContinuation<Void, Never>] = []
        func release() {
            let w = waiters
            waiters = []
            w.forEach { $0.resume() }
        }
    }

    final class Seen {
        var sets: [[AudioObjectID]] = []
    }

    private func makeResolver() -> ExclusionResolver {
        let gate = gate
        return ExclusionResolver(hal: hal, debounce: .milliseconds(500)) { _ in
            await withCheckedContinuation { gate.waiters.append($0) }
        }
    }

    private func observe(_ resolver: ExclusionResolver) -> Seen {
        let seen = Seen()
        resolver.onChange = { seen.sets.append($0) }
        return seen
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        gate.release()
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func mapsBundleIDsToProcessObjects() {
        let facetime = hal.addProcess(bundleID: "com.apple.FaceTime")
        let helper = hal.addProcess(bundleID: "com.apple.FaceTime.helper")
        hal.addProcess(bundleID: "com.apple.Music")
        let set = makeResolver().start(exclusions: [AppExclusion(bundleID: "com.apple.FaceTime", mode: .always)])
        #expect(set == [facetime, helper])
    }

    @Test func noExclusionsResolveToNothing() {
        hal.addProcess(bundleID: "us.zoom.xos")
        #expect(makeResolver().start(exclusions: []).isEmpty)
    }

    @Test func onlyDuringCallsFollowsInput() async {
        let zoom = hal.addProcess(bundleID: "us.zoom.xos")
        let resolver = makeResolver()
        let seen = observe(resolver)
        #expect(resolver.start(exclusions: [AppExclusion(bundleID: "us.zoom.xos", mode: .onlyDuringCalls)]).isEmpty)
        hal.setRunningInput(zoom, true)
        await settle()
        #expect(seen.sets == [[zoom]])
        hal.setRunningInput(zoom, false)
        await settle()
        #expect(seen.sets == [[zoom], []])
    }

    @Test func alwaysIgnoresInputState() async {
        let discord = hal.addProcess(bundleID: "com.hnc.Discord")
        let resolver = makeResolver()
        let seen = observe(resolver)
        #expect(resolver.start(exclusions: [AppExclusion(bundleID: "com.hnc.Discord", mode: .always)]) == [discord])
        hal.setRunningInput(discord, true)
        await settle()
        #expect(seen.sets.isEmpty)
    }

    @Test func launchAndQuitChangeTheSet() async {
        let resolver = makeResolver()
        let seen = observe(resolver)
        _ = resolver.start(exclusions: [AppExclusion(bundleID: "com.hnc.Discord", mode: .always)])
        let discord = hal.addProcess(bundleID: "com.hnc.Discord")
        await settle()
        hal.removeProcess(discord)
        await settle()
        #expect(seen.sets == [[discord], []])
    }

    @Test func burstIsDebouncedToOneChange() async {
        let resolver = makeResolver()
        let seen = observe(resolver)
        _ = resolver.start(exclusions: [AppExclusion(bundleID: "com.hnc.Discord", mode: .always)])
        var ids: [AudioObjectID] = []
        for _ in 0..<5 {
            ids.append(hal.addProcess(bundleID: "com.hnc.Discord.helper"))
            for _ in 0..<5 { await Task.yield() }
        }
        await settle()
        #expect(seen.sets.count == 1)
        #expect(seen.sets.first == ids)
    }

    @Test func unrelatedChangesDoNotReport() async {
        let resolver = makeResolver()
        let seen = observe(resolver)
        _ = resolver.start(exclusions: [AppExclusion(bundleID: "com.hnc.Discord", mode: .always)])
        hal.addProcess(bundleID: "com.apple.Music")
        await settle()
        #expect(seen.sets.isEmpty)
    }

    @Test func editingTheListChangesTheSet() async {
        let discord = hal.addProcess(bundleID: "com.hnc.Discord")
        let resolver = makeResolver()
        let seen = observe(resolver)
        _ = resolver.start(exclusions: [])
        resolver.update(exclusions: [AppExclusion(bundleID: "com.hnc.Discord", mode: .always)])
        await settle()
        #expect(seen.sets == [[discord]])
    }

    private func tapCount() -> Int {
        hal.ops.filter { if case .createTap = $0 { true } else { false } }.count
    }

    @Test func engineRebuildsTheTapOnlyWhenTheSetChanges() async {
        let engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        engine.excludedProcesses = [7]
        await engine.start(left: Self.gripA.uid, right: Self.gripB.uid)
        #expect(hal.ops.contains(.createTap(excluding: [42, 7])))
        let taps = tapCount()
        await engine.setExcludedProcesses([7])
        #expect(tapCount() == taps)
        await engine.setExcludedProcesses([7, 9])
        #expect(hal.ops.contains(.createTap(excluding: [42, 7, 9])))
        engine.stop()
    }
}
