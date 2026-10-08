import Foundation
import Testing
@testable import Domine

@MainActor
struct KeepAliveSettingTests {
    private func makeDefaults() -> UserDefaults {
        let name = "KeepAliveSettingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsToTrue() {
        #expect(SettingsStore(defaults: makeDefaults()).keepSpeakersAwake)
        #expect(GeneralSettingsState().keepSpeakersAwake)
    }

    @Test func roundTrips() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.keepSpeakersAwake = false
        #expect(!SettingsStore(defaults: defaults).keepSpeakersAwake)
        store.keepSpeakersAwake = true
        #expect(SettingsStore(defaults: defaults).keepSpeakersAwake)
    }

    @Test func wrongTypeReadsAsTrue() {
        let defaults = makeDefaults()
        defaults.set("no", forKey: "Domine.keepSpeakersAwake")
        #expect(SettingsStore(defaults: defaults).keepSpeakersAwake)
    }
}
