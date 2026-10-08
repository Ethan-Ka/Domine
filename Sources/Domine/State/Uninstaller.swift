import Foundation

/// Starts the bundled uninstall script. The launcher is injected so tests can
/// check the arguments without running anything.
struct Uninstaller {
    struct Launch: Equatable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    enum Failure: Error { case scriptMissing }

    var scriptPath: String?
    var appPath: String
    var pid: Int32
    var launcher: (Launch) throws -> Void

    func run(keepSettings: Bool) throws {
        guard let scriptPath else { throw Failure.scriptMissing }
        var arguments = [scriptPath, "--wait-pid", String(pid), "--yes"]
        if keepSettings { arguments.append("--keep-settings") }
        var environment = ProcessInfo.processInfo.environment
        environment["DOMINE_APP_PATH"] = appPath
        try launcher(Launch(executable: "/bin/bash", arguments: arguments, environment: environment))
    }

    /// The real launcher: standard streams go to /dev/null so the script
    /// outlives the app and is reparented when the app exits.
    static func launchProcess(_ launch: Launch) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func live() -> Uninstaller {
        Uninstaller(
            scriptPath: Bundle.main.path(forResource: "uninstall", ofType: "sh"),
            appPath: Bundle.main.bundlePath,
            pid: ProcessInfo.processInfo.processIdentifier,
            launcher: launchProcess)
    }
}
