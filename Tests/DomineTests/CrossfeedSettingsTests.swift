import Foundation
import Testing
@testable import Domine

@MainActor
struct CrossfeedSettingsTests {
    @Test func effectiveAmountFollowsSliderOrToggle() {
        #expect(PairSettings().effectiveCrossfeed == 0)
        #expect(PairSettings(crossfeed: 0.4).effectiveCrossfeed == 0.4)
        #expect(PairSettings(crossfeed: 0.4, sameOnBoth: true).effectiveCrossfeed == 1)
        #expect(PairSettings(crossfeed: 7).effectiveCrossfeed == 1)
        #expect(PairSettings(crossfeed: -1).effectiveCrossfeed == 0)
    }

    @Test func oldJSONDecodesWithDefaults() throws {
        let json = #"{"delayMs":12,"balance":0.25}"#
        let s = try JSONDecoder().decode(PairSettings.self, from: Data(json.utf8))
        #expect(s.crossfeed == 0)
        #expect(s.sameOnBoth == false)
        #expect(s.delayMs == 12)
    }

    @Test func newFieldsRoundTrip() throws {
        let s = PairSettings(crossfeed: 0.6, sameOnBoth: true)
        let back = try JSONDecoder().decode(PairSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func modelPushesEffectiveValueToEngine() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let model = AppModel(hal: FakeHAL(), defaults: defaults, services: FakeSystem().services)
        model.updatePairSettings { $0.crossfeed = 0.3 }
        #expect(model.engine.crossfeed == 0.3)
        model.updatePairSettings { $0.sameOnBoth = true }
        #expect(model.engine.crossfeed == 1)
    }
}
