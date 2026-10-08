import Darwin
import Foundation

/// A launched watchdog process (`PauseWatchdogProcess`). Tests pass fakes.
@MainActor
protocol PauseWatchdogHandle: AnyObject {
    var isRunning: Bool { get }
    /// SIGTERM: the watchdog exits without pausing.
    func cancel()
}

/// Keeps one watchdog process alive while Domine routes with "Pause
/// playback if Domine quits while playing" on (SPEC 16.11). If Domine
/// quits or crashes while it runs, the watchdog pauses media playback.
@MainActor
final class PauseWatchdog {
    typealias Launch = @MainActor () -> (any PauseWatchdogHandle)?

    private let launch: Launch
    private var handle: (any PauseWatchdogHandle)?
    private var isTerminating = false

    init(launch: @escaping Launch) {
        self.launch = launch
    }

    /// The real watchdog, or one that never launches in the unit test host.
    static func live(isTestHost: Bool = DomineApp.isTestHost) -> PauseWatchdog {
        PauseWatchdog { isTestHost ? nil : ProcessWatchdogHandle.launch() }
    }

    var isRunning: Bool { handle?.isRunning == true }

    /// Starts a watchdog while routing with the setting on; cancels it otherwise.
    func update(routing: Bool, enabled: Bool) {
        guard !isTerminating else { return }
        if routing && enabled {
            guard !isRunning else { return }
            handle?.cancel()
            handle = launch()
        } else {
            handle?.cancel()
            handle = nil
        }
    }

    /// Domine is quitting: leave a running watchdog alone so it pauses
    /// playback once Domine has exited, and launch nothing more.
    func appWillTerminate() {
        isTerminating = true
        handle = nil
    }
}
