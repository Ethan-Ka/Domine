import DomineDSP
import Foundation
import Testing

struct BassTests {
    static let sr = 48_000.0

    static func make(enabled: Bool = true, amount: Float = 1, cutoff: Float = 120) -> OpaquePointer {
        let b = domine_bass_create(sr)!
        var p = DomineBassParams(enabled: enabled ? 1 : 0, amount: amount, cutoffHz: cutoff)
        domine_bass_set_params(b, &p)
        return b
    }

    static func sine(_ hz: Double, _ n: Int, _ amp: Float = 0.5) -> [Float] {
        (0..<n).map { amp * Float(sin(2 * Double.pi * hz * Double($0) / sr)) }
    }

    static func run(_ b: OpaquePointer, _ input: [Float]) -> [Float] {
        var out = input
        var offset = 0
        while offset < out.count {
            let n = min(256, out.count - offset)
            out.withUnsafeMutableBufferPointer { domine_bass_process(b, $0.baseAddress! + offset, UInt32(n)) }
            offset += n
        }
        return out
    }

    /// Magnitude of one DFT bin over the last whole second.
    static func level(_ x: [Float], _ hz: Double) -> Double {
        let tail = x.suffix(48_000)
        var re = 0.0, im = 0.0
        for (i, v) in tail.enumerated() {
            let w = 2 * Double.pi * hz * Double(i) / sr
            re += Double(v) * cos(w)
            im += Double(v) * sin(w)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(tail.count)
    }

    @Test func disabledIsBitExact() {
        let b = Self.make(enabled: false)
        defer { domine_bass_destroy(b) }
        let input = Self.sine(80, 4800) + Self.sine(1000, 4800, 0.9)
        #expect(Self.run(b, input) == input)
    }

    @Test func addsHarmonicsOfEightyHertz() {
        let b = Self.make()
        defer { domine_bass_destroy(b) }
        let input = Self.sine(80, 96_000)
        let out = Self.run(b, input)
        #expect(Self.level(out, 160) > Self.level(input, 160) + 0.01)
        #expect(Self.level(out, 240) > Self.level(input, 240) + 0.01)
    }

    @Test func doesNotRaiseEnergyBelowSixtyHertz() {
        for hz in [30.0, 40.0, 50.0, 55.0] {
            let b = Self.make()
            let input = Self.sine(hz, 96_000)
            let out = Self.run(b, input)
            domine_bass_destroy(b)
            #expect(Self.level(out, hz) <= Self.level(input, hz) * 1.03, "\(hz) Hz")
        }
    }

    @Test func peakStaysUnderSixDecibels() {
        for hz in [60.0, 80.0, 120.0, 200.0, 500.0] {
            let b = Self.make()
            let out = Self.run(b, Self.sine(hz, 48_000, 1.0))
            domine_bass_destroy(b)
            #expect(out.map(abs).max()! < 2.0, "\(hz) Hz")
        }
        let b = Self.make()
        defer { domine_bass_destroy(b) }
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<48_000).map { _ in Float.random(in: -1...1, using: &rng) }
        #expect(Self.run(b, noise).map(abs).max()! < 2.0)
    }

    @Test func noNaNOnExtremeInput() {
        let b = Self.make(amount: 1, cutoff: 5000)
        defer { domine_bass_destroy(b) }
        let input = [Float](repeating: 0, count: 100) + [Float](repeating: 1, count: 1000)
            + Self.sine(80, 4800, 4.0)
        #expect(Self.run(b, input).allSatisfy { $0.isFinite })
    }

    @Test func parameterChangeIsSmooth() {
        let b = Self.make(amount: 0)
        defer { domine_bass_destroy(b) }
        let input = Self.sine(80, 48_000)
        let before = Self.run(b, Array(input[..<9600]))
        var p = DomineBassParams(enabled: 1, amount: 1, cutoffHz: 120)
        domine_bass_set_params(b, &p)
        let after = Self.run(b, Array(input[9600...]))
        let all = before + after
        var maxStep: Float = 0
        for i in 1..<all.count {
            maxStep = max(maxStep, abs((all[i] - input[i]) - (all[i - 1] - input[i - 1])))
        }
        #expect(maxStep < 0.05)
        #expect(before == Array(input[..<9600]))
    }
}
