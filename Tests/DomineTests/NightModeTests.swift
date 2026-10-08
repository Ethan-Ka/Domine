import Foundation
import Testing
@testable import Domine

struct NightModeTests {
    @Test func offUsesUserCompressor() {
        var fx = PairSettings.SideEffects()
        fx.compressorEnabled = true
        fx.compressorAmount = 0.5
        let p = fx.compressorParams
        #expect(p.enabled == 1)
        #expect(p.thresholdDb == fx.compressorThresholdDb)
        #expect(p.ratio == fx.compressorRatio)
    }

    @Test func onOverridesCompressorAndAddsLoudness() {
        var fx = PairSettings.SideEffects()
        fx.nightMode = true
        let p = fx.compressorParams
        #expect(p.enabled == 1)
        #expect(p.thresholdDb == -30)
        #expect(p.ratio == 6)
        #expect(p.makeupDb == 6)
        #expect(fx.eqParams.enabled == 1)
        #expect(fx.effectiveEQGains == [5, 1, -1, 1, 4])
    }

    @Test func offRestoresUserSettingsExactly() {
        var fx = PairSettings.SideEffects()
        fx.compressorAmount = 0.3
        fx.eqEnabled = true
        fx.eqBands[0].gainDb = 3
        let before = fx
        var e = PairSettings.EffectsSettings(both: fx)
        e = e.settingNightMode(true)
        #expect(e.left.nightMode && e.effectiveRight.nightMode)
        #expect(e.left.compressorAmount == 0.3)
        e = e.settingNightMode(false)
        #expect(e.left == before)
        #expect(e.left.compressorParams.enabled == 0)
    }

    @Test func oldJSONDecodesWithNightOff() throws {
        let json = #"{"delayMs":5,"effects":{"linkSpeakers":true,"left":{"compressorEnabled":true}}}"#
        let s = try JSONDecoder().decode(PairSettings.self, from: Data(json.utf8))
        #expect(!s.effects.left.nightMode)
        #expect(s.effects.left.compressorEnabled)
        var on = s
        on.effects = on.effects.settingNightMode(true)
        let back = try JSONDecoder().decode(PairSettings.self, from: JSONEncoder().encode(on))
        #expect(back.effects.nightMode)
    }
}
