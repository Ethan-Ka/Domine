import Foundation
import Testing
@testable import Domine

@MainActor
struct UpdateCheckerTests {
    final class Box { var items: [UpdateOutcome] = [] }

    static func json(tag: String, pkg: Bool) -> Data {
        let assets = pkg
            ? #"[{"name":"Domine.zip","browser_download_url":"https://x/z"},{"name":"Domine-1.pkg","browser_download_url":"https://x/p.pkg"}]"#
            : "[]"
        return Data(#"{"tag_name":"\#(tag)","html_url":"https://x/release","assets":\#(assets)}"#.utf8)
    }

    static func make(
        current: String = "0.1", data: Data? = nil, fail: Bool = false,
        testHost: Bool = false, now: @escaping () -> Date = Date.init,
        presented: Box = Box()
    ) -> UpdateChecker {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return UpdateChecker(
            currentVersion: current, isTestHost: testHost, defaults: defaults, now: now,
            fetch: { _ in
                if fail { throw URLError(.notConnectedToInternet) }
                return data ?? Data()
            },
            present: { presented.items.append($0) })
    }

    @Test func versionCompare() {
        #expect(SemanticVersion("v1.10.0")! > SemanticVersion("1.9.9")!)
        #expect(SemanticVersion("1.0")! == SemanticVersion("v1.0.0")!)
        #expect(SemanticVersion("0.1")! < SemanticVersion("0.1.1")!)
        #expect(SemanticVersion("junk") == nil)
    }

    @Test func newerOlderEqual() async {
        let newer = await Self.make(data: Self.json(tag: "v0.2.0", pkg: true)).check()
        #expect(newer == .available(version: "0.2.0", url: URL(string: "https://x/p.pkg")!))
        #expect(await Self.make(data: Self.json(tag: "v0.0.9", pkg: true)).check() == .upToDate)
        #expect(await Self.make(data: Self.json(tag: "v0.1.0", pkg: true)).check() == .upToDate)
    }

    @Test func missingPkgFallsBackToReleasePage() async {
        let out = await Self.make(data: Self.json(tag: "v0.2.0", pkg: false)).check()
        #expect(out == .available(version: "0.2.0", url: URL(string: "https://x/release")!))
    }

    @Test func launchCheckThrottledTo24Hours() async throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let box = Box()
        let c = Self.make(data: Self.json(tag: "v0.2.0", pkg: true), now: { clock }, presented: box)
        c.checkAtLaunch()
        try await Task.sleep(for: .milliseconds(150))
        #expect(box.items.count == 1)
        clock += 3600
        c.checkAtLaunch()
        try await Task.sleep(for: .milliseconds(150))
        #expect(box.items.count == 1)
        clock += 24 * 3600
        c.checkAtLaunch()
        try await Task.sleep(for: .milliseconds(150))
        #expect(box.items.count == 2)
    }

    @Test func testHostNeverChecks() async throws {
        let box = Box()
        let c = Self.make(data: Self.json(tag: "v9", pkg: true), testHost: true, presented: box)
        c.checkAtLaunch()
        c.checkManually()
        try await Task.sleep(for: .milliseconds(150))
        #expect(box.items.isEmpty)
    }

    @Test func errorsSilentWhenAutomaticAlertWhenManual() async {
        let box = Box()
        let c = Self.make(fail: true, presented: box)
        await c.run(manual: false)
        #expect(box.items.isEmpty)
        await c.run(manual: true)
        #expect(box.items == [.failed])
    }

    @Test func upToDateOnlyShownWhenManual() async {
        let box = Box()
        let c = Self.make(data: Self.json(tag: "v0.1", pkg: true), presented: box)
        await c.run(manual: false)
        #expect(box.items.isEmpty)
        await c.run(manual: true)
        #expect(box.items == [.upToDate])
    }
}
