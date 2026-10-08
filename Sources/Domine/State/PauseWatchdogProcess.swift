import Darwin
import Foundation

/// The watchdog side of "Pause playback if Domine quits while playing"
/// (SPEC 16.11). Domine relaunches its own executable with
/// `--pause-watchdog <pid>`. That process waits for Domine to exit, sends
/// MediaRemote pause, and exits. SIGTERM means Domine stopped routing on
/// its own: exit without pausing. Runs before NSApplication or any AppKit
/// setup, so it never shows a Dock icon or a window.
enum PauseWatchdogProcess {
    static let argument = "--pause-watchdog"

    /// The parent PID when the arguments ask for watchdog mode, else nil.
    static func parentPID(arguments: [String]) -> pid_t? {
        guard let index = arguments.firstIndex(of: argument),
              arguments.indices.contains(index + 1),
              let pid = pid_t(arguments[index + 1]), pid > 1
        else { return nil }
        return pid
    }

    /// Never returns in watchdog mode. Otherwise returns at once.
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let parent = parentPID(arguments: arguments) else { return }
        if waitForParentExit(parent) {
            MediaRemoteCommand.pause.send()
            // The command goes out over XPC; give it a moment before exiting.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        exit(0)
    }

    /// True when the parent exited, false when SIGTERM cancelled the wait.
    private static func waitForParentExit(_ parent: pid_t) -> Bool {
        signal(SIGTERM, SIG_IGN)
        // Reparented to launchd: the parent is already gone.
        if getppid() != parent { return true }
        let queue = kqueue()
        guard queue >= 0 else { return true }
        var changes = [
            kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                   fflags: NOTE_EXIT, data: 0, udata: nil),
            kevent(ident: UInt(SIGTERM), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD),
                   fflags: 0, data: 0, udata: nil),
        ]
        // Register one at a time so ESRCH on the process filter is not lost.
        for index in changes.indices {
            if kevent(queue, &changes[index], 1, nil, 0, nil) == -1 {
                if changes[index].filter == Int16(EVFILT_PROC) { return true }
            }
        }
        var event = kevent()
        while true {
            let count = kevent(queue, nil, 0, &event, 1, nil)
            if count == -1 {
                if errno == EINTR { continue }
                return true
            }
            if count == 1 {
                return event.filter != Int16(EVFILT_SIGNAL)
            }
        }
    }
}
