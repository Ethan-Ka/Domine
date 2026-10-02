import DomineDSP
import Testing

struct DemoTests {
    static let rate = 48000.0

    static func frame(_ seconds: Double, _ rate: Double = rate) -> UInt64 {
        UInt64((seconds * rate).rounded())
    }

    struct Hit {
        let frame: UInt64
        let azimuth: Float
        let omni: Float
        let section: Int32
    }

    /// Kick onset at frame f, if the tick that rendered f started one.
    static func onset(_ d: DomineDemo, _ f: UInt64) -> Hit? {
        let k = d.lastKick
        let active = k == 0 ? d.kickActive.0 : d.kickActive.1
        let start = k == 0 ? d.kickStart.0 : d.kickStart.1
        guard active != 0, start == f else { return nil }
        return Hit(frame: f,
                   azimuth: k == 0 ? d.kickAz.0 : d.kickAz.1,
                   omni: k == 0 ? d.kickOmni.0 : d.kickOmni.1,
                   section: d.section)
    }

    /// Runs the whole demo and returns every kick onset.
    static func hits(_ azimuths: [Float]) -> [Hit] {
        var d = DomineDemo()
        domine_demo_reset(&d, rate, UInt32(azimuths.count), azimuths)
        var v = [DomineDemoVoice](repeating: DomineDemoVoice(), count: Int(DOMINE_DEMO_VOICES))
        var out: [Hit] = []
        for f in 0..<frame(32) {
            _ = domine_demo_tick(&d, &v)
            if let h = onset(d, f) { out.append(h) }
        }
        return out
    }

    @Test(arguments: [44100.0, 48000.0])
    func sectionBoundariesAtExactFrames(rate: Double) {
        var d = DomineDemo()
        let az: [Float] = [-90, 90]
        domine_demo_reset(&d, rate, 2, az)
        var v = [DomineDemoVoice](repeating: DomineDemoVoice(), count: Int(DOMINE_DEMO_VOICES))
        var changes: [(UInt64, Int32)] = []
        var prev = Int32(DOMINE_DEMO_SECTION_ROLL_CALL)
        for f in 0..<(Self.frame(32, rate) + 100) {
            let s = domine_demo_tick(&d, &v)
            if s != prev { changes.append((f, s)); prev = s }
        }
        let expected: [(Double, Int32)] = [
            (8, DOMINE_DEMO_SECTION_PING_PONG), (14, DOMINE_DEMO_SECTION_ORBIT),
            (26, DOMINE_DEMO_SECTION_SWELL), (30, DOMINE_DEMO_SECTION_DROP),
            (32, DOMINE_DEMO_SECTION_FINISHED),
        ]
        #expect(changes.count == expected.count)
        for (c, e) in zip(changes, expected) {
            #expect(c.0 == Self.frame(e.0, rate))
            #expect(c.1 == e.1)
        }
    }

    @Test func rollCallGoesClockwiseFromHardLeftTwiceForFive() {
        let hits = Self.hits([0, 110, -30, -90, 30]).filter { $0.section == DOMINE_DEMO_SECTION_ROLL_CALL }
        let order: [Float] = [-90, -30, 0, 30, 110]
        #expect(hits.count == 10)
        for (i, h) in hits.enumerated() {
            #expect(h.azimuth == order[i % 5])
            #expect(h.omni == 0)
            #expect(h.frame == UInt64((Double(i) * 8 * Self.rate / 10).rounded()))
        }
    }

    @Test func rollCallIsOneRoundAboveEightSpeakers() {
        let az = (0..<9).map { Float($0) * 40 - 160 }
        let hits = Self.hits(az).filter { $0.section == DOMINE_DEMO_SECTION_ROLL_CALL }
        let order: [Float] = [-80, -40, 0, 40, 80, 120, 160, -160, -120]
        #expect(hits.map(\.azimuth) == order)
    }

    @Test func pingPongAlternatesFromLeftWithShrinkingGaps() {
        let hits = Self.hits([-90, 90]).filter { $0.section == DOMINE_DEMO_SECTION_PING_PONG }
        #expect(hits.count >= 15)
        #expect(hits.first?.frame == Self.frame(8))
        for (i, h) in hits.enumerated() {
            #expect(h.azimuth == (i % 2 == 0 ? -90 : 90))
        }
        let gaps = zip(hits.dropFirst(), hits).map { Double($0.frame - $1.frame) / Self.rate }
        #expect(abs(gaps[0] - 0.5) < 1e-4)
        for (a, b) in zip(gaps.dropFirst(), gaps) { #expect(a < b) }
        #expect(gaps.allSatisfy { $0 >= 0.15 - 1e-4 })
    }

    @Test func dropIsOmniAndDemoFinishesSilent() {
        let hits = Self.hits([-30, 30])
        let drop = hits.filter { $0.section == DOMINE_DEMO_SECTION_DROP }
        #expect(drop.count == 1)
        #expect(drop.first?.frame == Self.frame(30))
        #expect(drop.first?.omni == 1)

        var d = DomineDemo()
        let az: [Float] = [-30, 30]
        domine_demo_reset(&d, Self.rate, 2, az)
        var v = [DomineDemoVoice](repeating: DomineDemoVoice(), count: Int(DOMINE_DEMO_VOICES))
        for _ in 0..<Self.frame(32) { _ = domine_demo_tick(&d, &v) }
        for _ in 0..<1000 {
            #expect(domine_demo_tick(&d, &v) == DOMINE_DEMO_SECTION_FINISHED)
            #expect(v.allSatisfy { $0.sample == 0 })
        }
        #expect(abs(domine_demo_seconds(&d) - 32) < 1e-9)
    }

    @Test func peaksStayWithinLimitsAndFinite() {
        var d = DomineDemo()
        let az: [Float] = [-45, 45, 135, -135]
        domine_demo_reset(&d, Self.rate, 4, az)
        var v = [DomineDemoVoice](repeating: DomineDemoVoice(), count: Int(DOMINE_DEMO_VOICES))
        var voicePeak: Float = 0
        var sumPeak: Float = 0
        var allFinite = true
        for _ in 0..<Self.frame(32) {
            _ = domine_demo_tick(&d, &v)
            var sum: Float = 0
            for x in v {
                if !x.sample.isFinite || !x.azimuth.isFinite || !x.omni.isFinite { allFinite = false }
                voicePeak = max(voicePeak, abs(x.sample))
                sum += abs(x.sample)
            }
            sumPeak = max(sumPeak, sum)
        }
        #expect(allFinite)
        #expect(voicePeak <= 0.8)
        #expect(voicePeak > 0.6)
        #expect(sumPeak <= 1.0)
    }

    @Test func twoResetsGiveIdenticalSamples() {
        let az: [Float] = [-45, 45, 135, -135]
        var a = DomineDemo()
        var b = DomineDemo()
        domine_demo_reset(&a, Self.rate, 4, az)
        domine_demo_reset(&b, 44100, 2, az)
        var va = [DomineDemoVoice](repeating: DomineDemoVoice(), count: Int(DOMINE_DEMO_VOICES))
        var vb = va
        for _ in 0..<50000 { _ = domine_demo_tick(&b, &vb) }
        domine_demo_reset(&b, Self.rate, 4, az)
        var same = true
        for _ in 0..<Self.frame(32) {
            if domine_demo_tick(&a, &va) != domine_demo_tick(&b, &vb) { same = false }
            for i in 0..<va.count where va[i].sample != vb[i].sample || va[i].azimuth != vb[i].azimuth
                || va[i].omni != vb[i].omni {
                same = false
            }
        }
        #expect(same)
    }
}
