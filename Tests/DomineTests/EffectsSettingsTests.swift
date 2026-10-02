import DomineDSP
import Foundation
import Testing
@testable import Domine

@MainActor
struct EffectsSettingsTests {
    @Test func defaultsMatchSpec() {
        let fx = PairSettings().effects
        #expect(fx.linkSpeakers)
        #expect(fx.left.eqBands.map(\.freqHz) == [80, 250, 1000, 4000, 10_000])
        #expect(fx.left.eqBands.allSatisfy { $0.gainDb == 0 && $0.q == 1 })
        #expect(!fx.left.eqEnabled && !fx.left.bassEnabled && !fx.left.compressorEnabled)
    }

    @Test func roundTrip() throws {
        var s = PairSettings(delayMs: 5)
        s.effects = PairSettings.Preset.night.settings
        s.effects.linkSpeakers = false
        s.effects.right.bassEnabled = true
        let back = try JSONDecoder().decode(PairSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func oldJSONDecodesToDefaults() throws {
        let json = #"{"delayMs":12,"extendedRange":false,"balance":0.25,"masterVolume":0.4}"#
        let s = try JSONDecoder().decode(PairSettings.self, from: Data(json.utf8))
        #expect(s.delayMs == 12)
        #expect(s.effects == PairSettings.EffectsSettings())
    }

    @Test func compressorMapping() {
        var s = PairSettings.SideEffects()
        s.compressorAmount = 0
        #expect(s.compressorThresholdDb == -6 && s.compressorRatio == 1.5)
        s.compressorAmount = 1
        #expect(s.compressorThresholdDb == -30 && s.compressorRatio == 4)
        #expect(s.compressorMakeupDb > 0)
    }

    @Test func presets() {
        #expect(PairSettings.Preset.flat.settings == PairSettings.EffectsSettings())
        let boost = PairSettings.Preset.bassBoost.settings.left
        #expect(boost.eqEnabled && boost.eqBands[0].gainDb == 6 && boost.bassEnabled && boost.bassAmount == 0.5)
        let night = PairSettings.Preset.night.settings.left
        #expect(night.compressorEnabled && night.compressorAmount == 0.7)
        #expect(PairSettings.Preset.allCases.map(\.rawValue) == ["Flat", "Bass Boost", "Vocal", "Loudness", "Night"])
        for p in PairSettings.Preset.allCases {
            #expect(p.settings.left.eqBands.allSatisfy { abs($0.gainDb) <= 12 })
        }
    }

    @Test func swappedPairSwapsEffects() {
        var s = PairSettings()
        s.effects.left.bassEnabled = true
        #expect(s.swapped.effects.right.bassEnabled)
        #expect(!s.swapped.effects.left.bassEnabled)
    }

    @Test func linkedRightFollowsLeft() {
        var fx = PairSettings.Preset.vocal.settings
        #expect(fx.effectiveRight == fx.left)
        fx.linkSpeakers = false
        fx.right = PairSettings.SideEffects()
        #expect(fx.effectiveRight != fx.left)
    }

    @Test func enginePushesPerPositionAndIgnoresSwap() async {
        let hal = FakeHAL()
        let engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero)
        hal.add(EngineTests.gripA)
        hal.add(EngineTests.gripB)
        await engine.start(left: EngineTests.gripA.uid, right: EngineTests.gripB.uid)
        var l = PairSettings.SideEffects()
        l.eqEnabled = true
        l.eqBands[0].gainDb = 6
        engine.setEffects(left: l, right: PairSettings.SideEffects())
        #expect(engine.pushedEQ.map(\.enabled) == [1, 0])
        engine.swapSides = true
        #expect(engine.pushedEQ.map(\.enabled) == [1, 0])
        let gain = withUnsafeBytes(of: engine.pushedEQ[0].bands) { $0.bindMemory(to: DomineEQBand.self)[0].gainDb }
        #expect(gain == 6)
    }
}
