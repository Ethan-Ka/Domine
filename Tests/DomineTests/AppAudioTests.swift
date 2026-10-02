import Foundation
import Testing
@testable import Domine

@MainActor
struct AppAudioTests {
    private static let identify: AppAudioList.Identify = { id in
        if id.hasPrefix("com.example.Player") { return ("com.example.Player", "Player") }
        if id.hasPrefix("us.zoom.xos") { return ("us.zoom.xos", "zoom.us") }
        return nil
    }

    private func makeList(_ hal: FakeHAL) -> AppAudioList {
        let list = AppAudioList(hal: hal, ownBundleID: "com.me.Domine", identify: Self.identify)
        list.start()
        return list
    }

    @Test func listsOnlyProcessesRunningOutput() {
        let hal = FakeHAL()
        hal.addProcess(bundleID: "us.zoom.xos")
        hal.addProcess(bundleID: "com.example.Player", isRunningOutput: true)
        hal.addProcess(bundleID: "com.unknown.daemon", isRunningOutput: true)
        hal.addProcess(bundleID: "com.me.Domine", isRunningOutput: true)
        let list = makeList(hal)
        #expect(list.apps == [PlayingApp(bundleID: "com.example.Player", name: "Player")])
    }

    @Test func groupsHelpersWithTheirApp() {
        let hal = FakeHAL()
        hal.addProcess(bundleID: "com.example.Player", isRunningOutput: true)
        hal.addProcess(bundleID: "com.example.Player.helper.Renderer", isRunningOutput: true)
        #expect(makeList(hal).apps.count == 1)
    }

    @Test func followsOutputAndProcessChanges() {
        let hal = FakeHAL()
        let list = makeList(hal)
        #expect(list.apps.isEmpty)
        let id = hal.addProcess(bundleID: "us.zoom.xos")
        #expect(list.apps.isEmpty)
        hal.setRunningOutput(id, true)
        #expect(list.apps.map(\.bundleID) == ["us.zoom.xos"])
        hal.setRunningOutput(id, false)
        #expect(list.apps.isEmpty)
        hal.setRunningOutput(id, true)
        hal.removeProcess(id)
        #expect(list.apps.isEmpty)
    }

    @Test func volumeIsClampedAndPersisted() {
        let defaults = UserDefaults(suiteName: "AppAudioTests-\(UUID().uuidString)")!
        let model = AppModel(hal: FakeHAL(), defaults: defaults)
        model.setAppVolume(bundleID: "a.b", 0.4)
        model.setAppVolume(bundleID: "c.d", 7)
        #expect(model.appVolumes == ["a.b": 0.4, "c.d": 1])
        #expect(model.store.appVolumes == ["a.b": 0.4, "c.d": 1])
        #expect(AppModel(hal: FakeHAL(), defaults: defaults).appVolumes["a.b"] == 0.4)
    }

    @Test func excludeToggleUsesAlwaysExclusion() {
        let defaults = UserDefaults(suiteName: "AppAudioTests-\(UUID().uuidString)")!
        let model = AppModel(hal: FakeHAL(), defaults: defaults)
        model.setAppExcluded(bundleID: "us.zoom.xos", true)
        #expect(model.store.exclusions == [AppExclusion(bundleID: "us.zoom.xos", mode: .always)])
        model.exclusionsSettings.items[0].mode = .onlyDuringCalls
        model.setAppExcluded(bundleID: "us.zoom.xos", true)
        #expect(model.store.exclusions == [AppExclusion(bundleID: "us.zoom.xos", mode: .always)])
        model.setAppExcluded(bundleID: "us.zoom.xos", false)
        #expect(model.store.exclusions.isEmpty)
    }
}
