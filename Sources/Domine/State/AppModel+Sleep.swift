import AppKit

/// Sleep and wake bookkeeping for the model (SPEC 7).
@MainActor
final class SleepState {
    /// Routing was on when the Mac went to sleep.
    var resumeAfterWake = false
    var observers: [any NSObjectProtocol] = []
    /// The pending restart after wake, so tests can wait for it.
    var wakeTask: Task<Void, Never>?
    /// Settling time after wake before routing restarts.
    var wakeDelay: Duration = .seconds(2)
    /// How often to look for the speakers while they are missing.
    var pollInterval: Duration = .milliseconds(250)
    /// Give up waiting for the speakers after this long.
    var giveUpAfter: Duration = .seconds(60)
}

extension AppModel {
    /// Watches for sleep and wake on the center in `services.sleepWakeCenter`.
    func observeSleepAndWake() {
        let center = services.sleepWakeCenter
        let will = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.systemWillSleep() } }
        let did = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.systemDidWake() } }
        sleepState.observers = [will, did]
    }

    /// Stops routing before sleep and remembers that it was on.
    func systemWillSleep() {
        sleepState.wakeTask?.cancel()
        sleepState.wakeTask = nil
        guard engine.state.isActive else { return }
        Self.log.info("Going to sleep; stopping routing")
        sleepState.resumeAfterWake = true
        stopRouting()
    }

    /// Restarts routing about 2 s after wake, once the speakers are back.
    func systemDidWake() {
        guard sleepState.resumeAfterWake else { return }
        sleepState.wakeTask?.cancel()
        let state = sleepState
        state.wakeTask = Task { [weak self] in
            try? await Task.sleep(for: state.wakeDelay)
            var waited = Duration.zero
            while let self, !Task.isCancelled, !self.allSpeakersPresent {
                guard waited < state.giveUpAfter else { return }
                try? await Task.sleep(for: state.pollInterval)
                waited += state.pollInterval
            }
            guard let self, !Task.isCancelled else { return }
            state.resumeAfterWake = false
            Self.log.info("Woke; restarting routing")
            await self.startRouting()
        }
    }
}
