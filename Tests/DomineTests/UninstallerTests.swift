import XCTest
@testable import Domine

final class UninstallerTests: XCTestCase {
    private func make(script: String?, capture: @escaping (Uninstaller.Launch) -> Void) -> Uninstaller {
        Uninstaller(scriptPath: script, appPath: "/Applications/Domine.app", pid: 4242,
                    launcher: { capture($0) })
    }

    func testArgumentsWithoutKeepSettings() throws {
        var launch: Uninstaller.Launch?
        try make(script: "/x/uninstall.sh") { launch = $0 }.run(keepSettings: false)
        XCTAssertEqual(launch?.executable, "/bin/bash")
        XCTAssertEqual(launch?.arguments, ["/x/uninstall.sh", "--wait-pid", "4242", "--yes"])
    }

    func testArgumentsWithKeepSettings() throws {
        var launch: Uninstaller.Launch?
        try make(script: "/x/uninstall.sh") { launch = $0 }.run(keepSettings: true)
        XCTAssertEqual(launch?.arguments, ["/x/uninstall.sh", "--wait-pid", "4242", "--yes", "--keep-settings"])
    }

    func testAppPathEnvironment() throws {
        var launch: Uninstaller.Launch?
        try make(script: "/x/uninstall.sh") { launch = $0 }.run(keepSettings: false)
        XCTAssertEqual(launch?.environment["DOMINE_APP_PATH"], "/Applications/Domine.app")
    }

    func testMissingScriptThrowsAndLaunchesNothing() {
        var launched = false
        let uninstaller = make(script: nil) { _ in launched = true }
        XCTAssertThrowsError(try uninstaller.run(keepSettings: false))
        XCTAssertFalse(launched)
    }
}
