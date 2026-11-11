import Foundation

/// Runs the driver commands as root through `do shell script ... with
/// administrator privileges`, which shows the system password prompt.
/// osascript runs it in a child process so the main thread stays free while
/// the prompt is up and coreaudiod restarts.
struct LiveDriverInstaller: DriverInstalling {
    var bundledDriverURL: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Domine.driver"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func version(ofDriverAt url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleVersion"] as? String
    }

    func install(from source: URL, to destination: URL) async throws {
        // Root cannot read some user folders (~/Documents), so stage the
        // bundle in the user's temporary folder first.
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("domine-driver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let staged = stage.appendingPathComponent(destination.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: staged)
        } catch {
            throw DriverInstallError.failed(error.localizedDescription)
        }
        try await Self.runAsRoot(
            DriverCommand.install(from: staged.path, to: destination.path),
            prompt: "Domine needs your password to install its audio output.")
    }

    func remove(at destination: URL) async throws {
        try await Self.runAsRoot(
            DriverCommand.remove(at: destination.path),
            prompt: "Domine needs your password to remove its audio output.")
    }

    /// AppleScript error -128 is "User canceled".
    static func runAsRoot(_ command: String, prompt: String) async throws {
        let script = DriverCommand.appleScript(command, prompt: prompt)
        let result = await Task.detached { () -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errors = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            do {
                try process.run()
            } catch {
                return (-1, error.localizedDescription)
            }
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        guard result.0 != 0 else { return }
        if result.1.contains("(-128)") { throw DriverInstallError.cancelled }
        throw DriverInstallError.failed(result.1.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
