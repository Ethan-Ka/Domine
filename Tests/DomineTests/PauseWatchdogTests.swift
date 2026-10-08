import Foundation
import Testing
@testable import Domine

@MainActor
private final class FakeWatchdog: PauseWatchdogHandle {
    var isRunning = true
    var cancelCount = 0

    func cancel() {
        cancelCount += 1
        isRunning = false
    }
}

@MainActor
private final class FakeLauncher {
    var launched: [FakeWatchdog] = []

    func makeWatchdog() -> PauseWatchdog {
        PauseWatchdog { [self] in
            let watchdog = FakeWatchdog()
            launched.append(watchdog)
            return watchdog
        }
    }
}

@MainActor
struct PauseWatchdogTests {
    @Test func startsWhenRoutingAndEnabled() {
        let launcher = FakeLauncher()
        let watchdog = launcher.makeWatchdog()
        watchdog.update(routing: true, enabled: true)
        #expect(launcher.launched.count == 1)
        #expect(watchdog.isRunning)
    }

    @Test func doesNotStartWhenDisabled() {
        let launcher = FakeLauncher()
        let watchdog = launcher.makeWatchdog()
        watchdog.update(routing: true, enabled: false)
        #expect(launcher.launched.isEmpty)
    }

    @Test func doesNotStartWhenNotRouting() {
        let launcher = FakeLauncher()
        let watchdog = launcher.makeWatchdog()
        watchdog.update(routing: false, enabled: true)
        #expect(launcher.launched.isEmpty)
    }

    @Test func cancelledWhenRoutingStops() {
        let launcher = FakeLauncher()
        let watchdog = launcher.makeWatchdog()
        watchdog.update(routing: true, enabled: true)
        watchdog.update(routing: false, enabled: true)
        #expect(launcher.launched[0].cancelCount == 1)
        #expect(!watchdog.isRunning)
    }

    @Test func cancelledWhenSettingTurnedOff() {
        let launcher = FakeLauncher()
        let watchdog = launcher.makeWatchdog()
        watchdog.update(routing: true, enabled: true)
        watchdog.update(routing: true, enabled: false)
        #expect(launcher.launched[0].cancelCount == 1)
    }

    @Test func onlyOneInstance() {
        let launcher = FakeLauncher()
        let watchdog = launcher.makeWatchdog()
        watchdog.update(routing: true, enabled: true)
        watchdog.update(routing: true, enabled: true)
        watchdog.update(routing: true, enabled: true)
        #expect(launcher.launched.count == 1)
    }

    @Test func relaunchesIfTheWatchdogDied() {
        let launcher = FakeLauncher()
        let watchdog = launcher.makeWatchdog()
        watchdog.update(routing: true, enabled: true)
        launcher.launched[0].isRunning = false
        watchdog.update(routing: true, enabled: true)
        #expect(launcher.launched.count == 2)
    }

    @Test func keptAliveWhenAppTerminates() {
        let launcher = FakeLauncher()
        let watchdog = launcher.makeWatchdog()
        watchdog.update(routing: true, enabled: true)
        watchdog.appWillTerminate()
        // Quitting stops routing, which must not cancel or relaunch.
        watchdog.update(routing: false, enabled: true)
        watchdog.update(routing: true, enabled: true)
        #expect(launcher.launched.count == 1)
        #expect(launcher.launched[0].cancelCount == 0)
        #expect(launcher.launched[0].isRunning)
    }

    @Test func liveNeverLaunchesInTestHost() {
        let watchdog = PauseWatchdog.live(isTestHost: true)
        watchdog.update(routing: true, enabled: true)
        #expect(!watchdog.isRunning)
    }

    @Test func parsesWatchdogArgument() {
        #expect(PauseWatchdogProcess.parentPID(arguments: ["/app", "--pause-watchdog", "1234"]) == 1234)
        #expect(PauseWatchdogProcess.parentPID(arguments: ["/app"]) == nil)
        #expect(PauseWatchdogProcess.parentPID(arguments: ["/app", "--pause-watchdog"]) == nil)
        #expect(PauseWatchdogProcess.parentPID(arguments: ["/app", "--pause-watchdog", "abc"]) == nil)
        #expect(PauseWatchdogProcess.parentPID(arguments: ["/app", "--pause-watchdog", "1"]) == nil)
        #expect(PauseWatchdogProcess.parentPID(arguments: ["/app", "1234"]) == nil)
    }

    @Test func settingDefaultsToOnAndRoundTrips() {
        let name = "PauseWatchdogTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = SettingsStore(defaults: defaults)
        #expect(store.pauseOnExit)
        #expect(GeneralSettingsState().pauseOnExit)
        store.pauseOnExit = false
        #expect(!SettingsStore(defaults: defaults).pauseOnExit)
    }
}
