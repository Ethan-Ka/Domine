import Darwin
import Foundation

/// The watchdog as a child process: this app's executable with
/// `--pause-watchdog <pid>`.
@MainActor
final class ProcessWatchdogHandle: PauseWatchdogHandle {
    private let process: Process

    private init(process: Process) {
        self.process = process
    }

    static func launch() -> ProcessWatchdogHandle? {
        guard let path = Bundle.main.executablePath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [PauseWatchdogProcess.argument, String(getpid())]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        return ProcessWatchdogHandle(process: process)
    }

    var isRunning: Bool { process.isRunning }

    func cancel() {
        if process.isRunning { process.terminate() }
    }
}
