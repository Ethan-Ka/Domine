import DomineDSP
import Foundation
import Testing
@testable import Domine

struct EQBandSettingsTests {
    typealias Side = PairSettings.SideEffects

    static func decode(_ json: String) throws -> Side {
        try JSONDecoder().decode(Side.self, from: Data(json.utf8))
    }

    static func types(_ p: DomineEQParams) -> [Int32] {
        withUnsafeBytes(of: p.types) { Array($0.bindMemory(to: Int32.self)) }
    }

    static func bands(_ p: DomineEQParams) -> [DomineEQBand] {
        withUnsafeBytes(of: p.bands) { Array($0.bindMemory(to: DomineEQBand.self)) }
    }

    @Test func oldFiveBandJSONDecodesUnchanged() throws {
        let json = """
        {"eqEnabled":true,"eqBands":[
          {"freqHz":80,"gainDb":3,"q":1},{"freqHz":250,"gainDb":0,"q":1},{"freqHz":1000,"gainDb":-2,"q":1},
          {"freqHz":4000,"gainDb":1,"q":1},{"freqHz":10000,"gainDb":4,"q":1}],
         "nightMode":true}
        """
        let fx = try Self.decode(json)
        #expect(fx.eqBands.map(\.freqHz) == [80, 250, 1000, 4000, 10_000])
        #expect(fx.eqBands.map(\.gainDb) == [3, 0, -2, 1, 4])
        #expect(fx.eqBands.map(\.type) == [.lowShelf, .peak, .peak, .peak, .highShelf])
        #expect(fx.nightStrength == .medium)
        // Kernel parameters are exactly what the fixed five-band EQ got.
        let p = fx.eqParams
        #expect(p.bandCount == 5)
        #expect(Array(Self.types(p).prefix(5)) == [DOMINE_EQ_LOW_SHELF, DOMINE_EQ_PEAKING, DOMINE_EQ_PEAKING,
                                             DOMINE_EQ_PEAKING, DOMINE_EQ_HIGH_SHELF].map { Int32($0.rawValue) })
        #expect(Self.bands(p).prefix(5).map(\.gainDb) == [8, 1, -3, 2, 8])
    }

    @Test func defaultsMatchOldFixedBands() {
        let fx = Side()
        #expect(fx.eqBands.map(\.type) == [.lowShelf, .peak, .peak, .peak, .highShelf])
        #expect(fx.nightStrength == .medium)
    }

    @Test(arguments: 1...8)
    func anyCountFromOneToEightDecodes(count: Int) throws {
        let bands = (0..<count).map { #"{"freqHz":\#(100 * ($0 + 1)),"gainDb":2,"q":0.7,"type":"notch"}"# }
        let fx = try Self.decode(#"{"eqBands":[\#(bands.joined(separator: ","))]}"#)
        #expect(fx.eqBands.count == count)
        #expect(fx.eqBands.allSatisfy { $0.type == .notch && $0.q == 0.7 })
        #expect(fx.eqParams.bandCount == Int32(count))
    }

    @Test(arguments: [0, 9])
    func outOfRangeCountsResetToDefaults(count: Int) throws {
        let bands = Array(repeating: #"{"freqHz":500,"gainDb":2,"q":1}"#, count: count)
        let fx = try Self.decode(#"{"eqBands":[\#(bands.joined(separator: ","))]}"#)
        #expect(fx.eqBands == Side.defaultBands)
    }

    @Test func newBandJSONRoundTripsAndClamps() throws {
        let json = """
        {"eqBands":[{"freqHz":5,"gainDb":40,"q":0.01,"type":"highShelf"},
                    {"freqHz":30000,"gainDb":-3,"q":50,"type":"peak"},
                    {"freqHz":60,"gainDb":0,"q":8}]}
        """
        let fx = try Self.decode(json)
        #expect(fx.eqBands == [
            Side.Band(freqHz: 20, gainDb: 12, q: 0.3, type: .highShelf),
            Side.Band(freqHz: 20_000, gainDb: -3, q: 10, type: .peak),
            // Missing type on the last of several bands: high shelf.
            Side.Band(freqHz: 60, gainDb: 0, q: 8, type: .highShelf),
        ])
        let again = try JSONDecoder().decode(Side.self, from: JSONEncoder().encode(fx))
        #expect(again == fx)
    }

    @Test func nightModeSkipsNotchAndFollowsFrequency() {
        var fx = Side()
        fx.eqBands = [Side.Band(freqHz: 1000, gainDb: 0, q: 4, type: .notch), Side.Band(freqHz: 10_000, gainDb: 2)]
        fx.nightMode = true
        #expect(fx.effectiveEQGains == [0, 6])
        #expect(Array(Self.types(fx.eqParams).prefix(2)) == [Int32(DOMINE_EQ_NOTCH.rawValue), Int32(DOMINE_EQ_PEAKING.rawValue)])
    }

    @Test(arguments: [
        (PairSettings.NightStrength.light, Float(-24), Float(3), Float(3)),
        (.medium, -30, 6, 6),
        (.strong, -36, 10, 9),
    ])
    func nightStrengthMapsToCompressor(strength: PairSettings.NightStrength, threshold: Float, ratio: Float,
                                       makeup: Float) {
        var fx = Side()
        fx.nightMode = true
        fx.nightStrength = strength
        let p = fx.compressorParams
        #expect(p.enabled == 1)
        #expect(p.thresholdDb == threshold)
        #expect(p.ratio == ratio)
        #expect(p.makeupDb == makeup)
        #expect(p.attackMs == 2)
        #expect(p.releaseMs == 100)
        #expect(p.limiterCeilingDb == -1)
    }

    @Test func nightStrengthRoundTripsAndSetsBothSides() throws {
        var fx = Side()
        fx.nightStrength = .strong
        let back = try JSONDecoder().decode(Side.self, from: JSONEncoder().encode(fx))
        #expect(back.nightStrength == .strong)
        let e = PairSettings.EffectsSettings().settingNightStrength(.light)
        #expect(e.left.nightStrength == .light && e.right.nightStrength == .light)
    }

    @Test func addingBandFillsWidestGapAndStopsAtEight() {
        var bands = [Side.Band(freqHz: 1000)]
        bands = SoundState.addingBand(to: bands)
        #expect(bands.map(\.freqHz) == [141, 1000])
        for _ in 0..<10 { bands = SoundState.addingBand(to: bands) }
        #expect(bands.count == 8)
        #expect(bands.map(\.freqHz) == bands.map(\.freqHz).sorted())
        #expect(SoundState.removingBand(at: 0, from: [Side.Band(freqHz: 50)]).count == 1)
    }

    @Test func labelsCarryUnits() {
        #expect(SoundState.frequencyLabel(80) == "80 Hz")
        #expect(SoundState.frequencyLabel(1000) == "1 kHz")
        #expect(SoundState.frequencyLabel(12_500) == "12.5 kHz")
        #expect(SoundState.qLabel(0.7) == "Q 0.7")
        #expect(SoundState.gainLabel(3) == "+3 dB")
        #expect(SoundState.gainLabel(-3) == "-3 dB")
    }
}
