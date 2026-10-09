import DomineDSP
import Foundation
import Testing

struct CalibrationChirpTests {
    static let fade = 1920
    static let length = 5760 // 120 ms at 48 kHz
    static let period = 48_000

    static func template(rising: Bool) -> [Float] {
        var out = [Float](repeating: 0, count: length + 10)
        domine_calibration_chirp(&out, UInt32(out.count), 48_000, rising ? 1 : 0)
        return out
    }

    @Test func templateShape() {
        let up = Self.template(rising: true)
        let down = Self.template(rising: false)
        #expect(up[0] == 0 && down[0] == 0) // Hann starts at 0
        #expect(up[Self.length...].allSatisfy { $0 == 0 })
        #expect(up.map(abs).max()! <= 0.3 && up.map(abs).max()! > 0.28)
        // Exact value of a rising sample at n = 2000 (mid body, no taper or tail).
        let duration = 5760.0 / 48_000, ratio = 10.0
        let t = 2000.0 / 48_000
        let phase = 2 * Double.pi * 300 * duration / log(ratio) * (pow(ratio, t / duration) - 1)
        #expect(up[2000] == Float(0.3 * sin(phase)))
        // The tail: last 960 samples decay exponentially on top of the taper.
        let n = 5700.0, x = n / 5760
        let tailPhase = 2 * Double.pi * 300 * duration / log(ratio) * (pow(ratio, n / 48_000 / duration) - 1)
        let envelope = (0.5 - 0.5 * cos(Double.pi * (1 - x) / 0.125)) * exp(-3 * (n - 4800) / 960)
        #expect(up[5700] == Float(0.3 * envelope * sin(tailPhase)))
        // Falling chirp swaps the end frequencies.
        let downPhase = 2 * Double.pi * 3000 * duration / log(0.1) * (pow(0.1, t / duration) - 1)
        #expect(down[2000] == Float(0.3 * sin(downPhase)))
        #expect(up != down)
    }

    @Test func chirpsStartOnTheSameSampleAndMatchTheTemplate() {
        let kernel = Kernel()
        domine_kernel_set_click_test(kernel.raw, 2)
        let frames = Self.fade + Self.period + 300
        let (a, b) = ClickTestTests.run(kernel, frames: frames, chunk: 333)
        let up = Self.template(rising: true), down = Self.template(rising: false)
        #expect(a.prefix(Self.fade).allSatisfy { $0 == 0 })
        #expect(b.prefix(Self.fade).allSatisfy { $0 == 0 })
        for start in [Self.fade, Self.fade + Self.period] {
            #expect(Array(a[start..<(start + 300)]) == Array(up.prefix(300)))
            #expect(Array(b[start..<(start + 300)]) == Array(down.prefix(300)))
        }
        #expect(a[(Self.fade + Self.length)..<(Self.fade + Self.period)].allSatisfy { $0 == 0 })
        let firstA = a.firstIndex { $0 != 0 }!, firstB = b.firstIndex { $0 != 0 }!
        #expect(firstA == firstB)
    }

    @Test func delayIsBypassed() {
        let kernel = Kernel()
        domine_kernel_set_delay_ms(kernel.raw, 10)
        domine_kernel_set_click_test(kernel.raw, 2)
        let (a, b) = ClickTestTests.run(kernel, frames: Self.fade + 300)
        #expect(Array(a[Self.fade...]) == Array(Self.template(rising: true).prefix(300)))
        #expect(Array(b[Self.fade...]) == Array(Self.template(rising: false).prefix(300)))
    }

    /// Chirps play at full amplitude whatever the gains, so a quiet trim
    /// never makes a speaker too soft to measure (SPEC 12).
    @Test func gainsAreBypassed() {
        let kernel = Kernel()
        domine_kernel_set_gains(kernel.raw, 0.38, 0.25)
        domine_kernel_set_click_test(kernel.raw, 2)
        let (a, b) = ClickTestTests.run(kernel, frames: Self.fade + 300)
        #expect(Array(a[Self.fade...]) == Array(Self.template(rising: true).prefix(300)))
        #expect(Array(b[Self.fade...]) == Array(Self.template(rising: false).prefix(300)))
    }

    /// Chirp gains scale each chirp exactly, clamped to 0...1 (SPEC 12, test volume).
    @Test func chirpGainsScaleEachSide() {
        let kernel = Kernel()
        domine_kernel_set_chirp_gains(kernel.raw, 0.25, 3)
        domine_kernel_set_click_test(kernel.raw, 2)
        let (a, b) = ClickTestTests.run(kernel, frames: Self.fade + 300)
        #expect(Array(a[Self.fade...]) == Self.template(rising: true).prefix(300).map { $0 * 0.25 })
        #expect(Array(b[Self.fade...]) == Array(Self.template(rising: false).prefix(300)))
    }

    /// Mode 3 swaps the templates; the gains stay with their positions.
    @Test func swappedModePlaysFallingOnA() {
        let kernel = Kernel()
        domine_kernel_set_chirp_gains(kernel.raw, 0.5, 1)
        domine_kernel_set_click_test(kernel.raw, 3)
        let (a, b) = ClickTestTests.run(kernel, frames: Self.fade + 300)
        #expect(Array(a[Self.fade...]) == Self.template(rising: false).prefix(300).map { $0 * 0.5 })
        #expect(Array(b[Self.fade...]) == Array(Self.template(rising: true).prefix(300)))
    }

    @Test func negativeChirpGainSilencesTheChirp() {
        let kernel = Kernel()
        domine_kernel_set_chirp_gains(kernel.raw, 0.5, -1)
        domine_kernel_set_click_test(kernel.raw, 2)
        let (a, b) = ClickTestTests.run(kernel, frames: Self.fade + 300)
        #expect(Array(a[Self.fade...]) == Self.template(rising: true).prefix(300).map { $0 * 0.5 })
        #expect(b[Self.fade...].allSatisfy { $0 == 0 })
    }
}
