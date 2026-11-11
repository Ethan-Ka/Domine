import Foundation

/// Installs and removes the Domine output driver (SPEC 8d). The live one
/// shows the system admin password prompt; tests pass a fake.
@MainActor
protocol DriverInstalling: Sendable {
    /// The driver inside Domine.app, nil if the build has none.
    var bundledDriverURL: URL? { get }
    /// CFBundleVersion from the driver's Info.plist, nil if it is not there.
    func version(ofDriverAt url: URL) -> String?
    /// Copies `source` to `destination` as root and restarts coreaudiod.
    func install(from source: URL, to destination: URL) async throws
    /// Deletes `destination` as root and restarts coreaudiod.
    func remove(at destination: URL) async throws
}

enum DriverInstallError: Error, Equatable {
    /// The user closed the password prompt.
    case cancelled
    case failed(String)
    case unavailable
}

enum DriverPaths {
    static let installed = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/Domine.driver")
}

/// Reports nothing installed and refuses to act. The default, so a test
/// host never reaches the password prompt.
struct UnavailableDriverInstaller: DriverInstalling {
    var bundledDriverURL: URL? { nil }
    func version(ofDriverAt url: URL) -> String? { nil }
    func install(from source: URL, to destination: URL) async throws { throw DriverInstallError.unavailable }
    func remove(at destination: URL) async throws { throw DriverInstallError.unavailable }
}
