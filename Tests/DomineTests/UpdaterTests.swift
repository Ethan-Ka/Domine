import Testing
@testable import Domine

@MainActor
struct UpdaterTests {
    final class FakeDriver: UpdaterDriver {
        var automaticallyChecksForUpdates = true
        var started = false
        var checks = 0
        var onCanCheckChange: (@MainActor (Bool) -> Void)?

        func start(onCanCheckChange: @escaping @MainActor (Bool) -> Void) {
            started = true
            self.onCanCheckChange = onCanCheckChange
        }

        func checkForUpdates() { checks += 1 }
    }

    static let realKey = "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="

    @Test func placeholderKeyKeepsUpdaterOff() {
        var made = false
        let updater = Updater(publicKey: Updater.placeholderPublicKey, isTestHost: false) {
            made = true
            return FakeDriver()
        }
        #expect(!made)
        #expect(!updater.isEnabled)
        #expect(!updater.canCheckForUpdates)
        #expect(!updater.automaticallyChecksForUpdates)
    }

    @Test(arguments: [nil, "", "  ", "$(SPARKLE_PUBLIC_ED_KEY)"] as [String?])
    func missingKeyKeepsUpdaterOff(key: String?) {
        var made = false
        let updater = Updater(publicKey: key, isTestHost: false) {
            made = true
            return FakeDriver()
        }
        #expect(!made)
        #expect(!updater.isEnabled)
    }

    @Test func testHostKeepsUpdaterOffEvenWithRealKey() {
        var made = false
        let updater = Updater(publicKey: Self.realKey, isTestHost: true) {
            made = true
            return FakeDriver()
        }
        #expect(!made)
        #expect(!updater.isEnabled)
    }

    @Test func liveUpdaterIsOffInTestHost() {
        #expect(!Updater.live().isEnabled)
    }

    @Test func checkDoesNothingWhileOff() {
        let updater = Updater(publicKey: nil, isTestHost: false) { FakeDriver() }
        updater.checkForUpdates()
        #expect(!updater.canCheckForUpdates)
    }

    @Test func realKeyStartsDriverAndFollowsCanCheck() throws {
        let driver = FakeDriver()
        let updater = Updater(publicKey: Self.realKey, isTestHost: false) { driver }
        #expect(updater.isEnabled)
        #expect(driver.started)
        #expect(updater.automaticallyChecksForUpdates)

        updater.checkForUpdates()
        #expect(driver.checks == 0)

        let report = try #require(driver.onCanCheckChange)
        report(true)
        #expect(updater.canCheckForUpdates)
        updater.checkForUpdates()
        #expect(driver.checks == 1)

        report(false)
        #expect(!updater.canCheckForUpdates)
    }

    @Test func automaticChecksWriteThroughToDriver() {
        let driver = FakeDriver()
        let updater = Updater(publicKey: Self.realKey, isTestHost: false) { driver }
        updater.automaticallyChecksForUpdates = false
        #expect(!driver.automaticallyChecksForUpdates)
    }
}
