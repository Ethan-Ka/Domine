import Foundation
import Testing
@testable import Domine

/// Records install and remove calls. Versions come from a fake plist table by path.
@MainActor
final class FakeDriverInstaller: DriverInstalling {
    struct Call: Equatable {
        var kind: String
        var source: String?
        var destination: String
    }

    var bundledDriverURL: URL? = URL(fileURLWithPath: "/Applications/Domine.app/Contents/Resources/Domine.driver")
    /// CFBundleVersion by driver path.
    var versions: [String: String] = [:]
    var calls: [Call] = []
    /// Thrown by the next install or remove instead of succeeding.
    var nextError: DriverInstallError?

    var bundledVersion: String? {
        get { bundledDriverURL.flatMap { versions[$0.path] } }
        set { if let url = bundledDriverURL { versions[url.path] = newValue } }
    }

    var installedVersion: String? {
        get { versions[DriverPaths.installed.path] }
        set { versions[DriverPaths.installed.path] = newValue }
    }

    func version(ofDriverAt url: URL) -> String? { versions[url.path] }

    func install(from source: URL, to destination: URL) async throws {
        calls.append(Call(kind: "install", source: source.path, destination: destination.path))
        if let error = nextError { nextError = nil; throw error }
        versions[destination.path] = versions[source.path]
    }

    func remove(at destination: URL) async throws {
        calls.append(Call(kind: "remove", source: nil, destination: destination.path))
        if let error = nextError { nextError = nil; throw error }
        versions[destination.path] = nil
    }
}

/// Settings > General > Setup, Domine output row, and the checklist step (SPEC 8d).
@MainActor
final class DriverInstallTests {
    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let system = FakeSystem()
    var driver: FakeDriverInstaller { system.driver }

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        system.driver.bundledVersion = "5"
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func makeModel() -> AppModel {
        AppModel(hal: hal, defaults: defaults, services: system.services)
    }

    @Test func notInstalled() {
        let state = makeModel().setupState
        #expect(state.driverStatus == .notInstalled)
        #expect(state.virtualOutputText == "Not installed")
        #expect(state.primaryDriverAction == .install)
        #expect(!state.showsRemoveDriver)
    }

    @Test func installed() {
        driver.installedVersion = "5"
        let state = makeModel().setupState
        #expect(state.driverStatus == .installed)
        #expect(state.virtualOutputText == "Installed")
        #expect(state.primaryDriverAction == nil)
        #expect(state.showsRemoveDriver)
    }

    @Test func updateAvailable() {
        driver.installedVersion = "4"
        let state = makeModel().setupState
        #expect(state.driverStatus == .updateAvailable)
        #expect(state.virtualOutputText == "Update available")
        #expect(state.primaryDriverAction == .update)
        #expect(state.showsRemoveDriver)
    }

    @Test func versionsCompareAsNumbers() {
        #expect(DriverStatus.make(installed: "9", bundled: "10", devicePresent: false) == .updateAvailable)
        #expect(DriverStatus.make(installed: "10", bundled: "9", devicePresent: false) == .installed)
        #expect(DriverStatus.make(installed: nil, bundled: "5", devicePresent: true) == .installed)
    }

    @Test func noBundledDriverFallsBackToInstallSteps() {
        driver.bundledDriverURL = nil
        let model = makeModel()
        #expect(model.setupState.primaryDriverAction == nil)
        #expect(!model.welcomeState.steps.contains { $0.kind == .installDriver })
    }

    @Test func installCopiesTheBundledDriverIntoHAL() async {
        let model = makeModel()
        await model.performDriverAction(.install)
        #expect(driver.calls == [FakeDriverInstaller.Call(
            kind: "install",
            source: "/Applications/Domine.app/Contents/Resources/Domine.driver",
            destination: "/Library/Audio/Plug-Ins/HAL/Domine.driver")])
        #expect(model.setupState.driverStatus == .installed)
        #expect(model.setupState.driverFailure == nil)
        #expect(model.setupState.driverActivity == nil)
    }

    @Test func showsProgressWhileRunning() {
        let model = makeModel()
        model.driverActivity = .install
        #expect(model.setupState.virtualOutputText == "Installing…")
        #expect(model.welcomeState.isInstallingDriver)
    }

    @Test func cancelChangesNothing() async {
        driver.installedVersion = "4"
        driver.nextError = .cancelled
        let model = makeModel()
        await model.performDriverAction(.update)
        #expect(driver.installedVersion == "4")
        #expect(model.setupState.driverStatus == .updateAvailable)
        #expect(model.setupState.driverFailure == "Cancelled. Nothing changed.")
    }

    @Test func failureShowsALine() async {
        driver.nextError = .failed("boom")
        let model = makeModel()
        await model.performDriverAction(.install)
        #expect(model.setupState.driverStatus == .notInstalled)
        #expect(model.setupState.driverFailure == "Could not install the Domine output.")
    }

    @Test func removeDeletesTheInstalledDriver() async {
        driver.installedVersion = "5"
        let model = makeModel()
        await model.performDriverAction(.remove)
        #expect(driver.calls.map(\.kind) == ["remove"])
        #expect(driver.calls.first?.destination == "/Library/Audio/Plug-Ins/HAL/Domine.driver")
        #expect(model.setupState.driverStatus == .notInstalled)
    }

    @Test func welcomeStepInstallsAndCanBeSkipped() async {
        let model = makeModel()
        #expect(model.welcomeState.steps.last?.kind == .installDriver)
        #expect(!model.welcomeState.isDone(.installDriver))
        await model.installDriverFromWelcome()
        #expect(driver.calls.map(\.kind) == ["install"])
        #expect(model.welcomeState.isDone(.installDriver))

        let other = makeModel()
        driver.installedVersion = nil
        other.refreshDriverVersion()
        other.welcomeActions.skipDriver()
        #expect(other.welcomeState.isDone(.installDriver))
        other.showSetupAgain()
        #expect(!other.welcomeState.isDone(.installDriver))
    }

    @Test func welcomeUpdatesAnOlderDriver() async {
        driver.installedVersion = "4"
        let model = makeModel()
        #expect(!model.welcomeState.isDone(.installDriver))
        await model.installDriverFromWelcome()
        #expect(driver.installedVersion == "5")
        #expect(model.welcomeState.isDone(.installDriver))
    }

    @Test func commandsQuotePaths() {
        let command = DriverCommand.install(from: "/tmp/it's here/Domine.driver", to: "/Library/Audio/Plug-Ins/HAL/Domine.driver")
        #expect(command.contains("/usr/bin/ditto '/tmp/it'\\''s here/Domine.driver' '/Library/Audio/Plug-Ins/HAL/Domine.driver'"))
        #expect(command.contains("/usr/sbin/chown -R root:wheel '/Library/Audio/Plug-Ins/HAL/Domine.driver'"))
        #expect(command.hasSuffix(DriverCommand.restartAudio))
        #expect(DriverCommand.literal("a \"b\" \\c") == "\"a \\\"b\\\" \\\\c\"")
    }
}
