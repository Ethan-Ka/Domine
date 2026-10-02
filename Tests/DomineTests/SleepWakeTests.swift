import AppKit
import Foundation
import Testing
@testable import Domine

@MainActor
final class SleepWakeTests {
    let hal = FakeHAL()
    let system = FakeSystem()
    let suiteName = UUID().uuidString
    let model: AppModel

    init() {
        let defaults = UserDefaults(suiteName: suiteName)!
        model = AppModel(hal: hal, defaults: defaults, services: system.services)
        model.sleepState.wakeDelay = .milliseconds(10)
        model.sleepState.pollInterval = .milliseconds(10)
        hal.add(AppModelTests.speakers)
        hal.add(EngineTests.gripA)
        hal.add(EngineTests.gripB)
        model.start()
    }

    deinit { UserDefaults().removePersistentDomain(forName: suiteName) }

    private func post(_ name: Notification.Name) {
        system.sleepWakeCenter.post(name: name, object: nil)
    }

    @Test func sleepThenWakeRestartsRouting() async {
        await model.startRouting()
        #expect(model.engine.state == .running)
        post(NSWorkspace.willSleepNotification)
        #expect(model.engine.state == .idle)
        #expect(hal.liveAggregateCount == 0)
        post(NSWorkspace.didWakeNotification)
        await model.sleepState.wakeTask?.value
        #expect(model.engine.state == .running)
    }

    @Test func sleepWhileOffDoesNothing() async {
        post(NSWorkspace.willSleepNotification)
        post(NSWorkspace.didWakeNotification)
        #expect(model.sleepState.wakeTask == nil)
        #expect(model.engine.state == .idle)
    }

    @Test func wakeWaitsForMissingSpeakers() async {
        await model.startRouting()
        post(NSWorkspace.willSleepNotification)
        hal.remove(uid: EngineTests.gripB.uid)
        post(NSWorkspace.didWakeNotification)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.engine.state == .idle)
        hal.add(EngineTests.gripB)
        await model.sleepState.wakeTask?.value
        #expect(model.engine.state == .running)
    }
}
