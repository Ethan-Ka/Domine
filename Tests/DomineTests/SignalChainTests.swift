import Testing
@testable import Domine

struct SignalChainTests {
    static func chain(source: Double? = 44_100, tap: Double = 44_100, aggregate: Double = 44_100,
                      a: Double? = 44_100, b: Double? = 44_100) -> SignalChain {
        SignalChain(sourceUID: "BuiltInSpeakerDevice", sourceRate: source, tapRate: tap, aggregateRate: aggregate,
                    speakers: [.init(label: "A", uid: "A:output", rate: a), .init(label: "B", uid: "B:output", rate: b)])
    }

    @Test func matchedRatesHaveNoConversion() {
        let chain = Self.chain()
        #expect(chain.isConversionFree)
        #expect(chain.summary == "default output BuiltInSpeakerDevice 44100 Hz, tap 44100 Hz, aggregate 44100 Hz, "
            + "Device A A:output 44100 Hz, Device B B:output 44100 Hz: no sample-rate conversion")
    }

    @Test func staleTapIsReportedAtBothStages() {
        let chain = Self.chain(tap: 48_000)
        #expect(chain.conversions == [
            "tap capture (default output 44100 Hz, tap 48000 Hz)",
            "aggregate input (tap 48000 Hz to 44100 Hz)",
        ])
        #expect(chain.summary.hasSuffix(": SRC at tap capture (default output 44100 Hz, tap 48000 Hz); "
            + "aggregate input (tap 48000 Hz to 44100 Hz)"))
    }

    @Test func speakerAtAnotherRateIsReported() {
        #expect(Self.chain(b: 48_000).conversions == ["Device B (44100 Hz to 48000 Hz)"])
    }

    @Test func unknownRatesAreNeverCalledClean() {
        #expect(Self.chain(a: nil).conversions == ["Device A (rate unknown)"])
        let noSource = Self.chain(source: nil)
        #expect(noSource.isConversionFree)
        #expect(noSource.summary.hasPrefix("default output BuiltInSpeakerDevice unknown rate, "))
    }

    @Test func fractionalRatesKeepTheirDigits() {
        #expect(SignalChain.hz(44_100) == "44100 Hz")
        #expect(SignalChain.hz(44_100.25) == "44100.250 Hz")
    }
}
