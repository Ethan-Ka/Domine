import DomineDSP
import Testing

struct DemoTests {
    static let rate = 48000.0
    static let stereo: [Float] = [-30, 30]

    static func frame(_ seconds: Double, _ rate: Double = rate) -> UInt64 {
        UInt64((seconds * rate).rounded())
    }

    static func voices() -> [DomineDemoVoice] {
        [DomineDemoVoice](repeating: DomineDemoVoice(), count: Int(DOMINE_DEMO_VOICES))
    }

    struct Hit {
        let frame: UInt64
        let azimuth: Float
        let omni: Float
        let gain: Float
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
                   gain: k == 0 ? d.kickGain.0 : d.kickGain.1,
                   section: d.section)
    }

    /// Runs the whole demo and returns every kick onset.
    static func hits(_ azimuths: [Float]) -> [Hit] {
        var d = DomineDemo()
        domine_demo_reset(&d, rate, UInt32(azimuths.count), azimuths)
        var v = voices()
        var out: [Hit] = []
        for f in 0..<frame(domine_demo_length(&d)) {
            _ = domine_demo_tick(&d, &v)
            if let h = onset(d, f) { out.append(h) }
        }
        return out
    }

    @Test func lengthFollowsSpeakerCount() {
        let az = (0..<16).map { Float($0) * 22.5 - 180 }
        let expected: [(Int, Double)] = [(2, 47), (3, 47), (4, 47), (5, 49), (6, 49), (8, 51), (9, 47), (16, 47)]
        for (n, len) in expected {
            var d = DomineDemo()
            domine_demo_reset(&d, Self.rate, UInt32(n), az)
            #expect(domine_demo_length(&d) == len)
            #expect(len <= DOMINE_DEMO_LENGTH_S)
        }
    }

    @Test(arguments: [44100.0, 48000.0])
    func sectionBoundariesAtExactFrames(rate: Double) {
        var d = DomineDemo()
        domine_demo_reset(&d, rate, 2, Self.stereo)
        var v = Self.voices()
        var changes: [(UInt64, Int32)] = []
        var prev = Int32(DOMINE_DEMO_SECTION_ROLL_CALL)
        for f in 0..<(Self.frame(47, rate) + 100) {
            let s = domine_demo_tick(&d, &v)
            if s != prev { changes.append((f, s)); prev = s }
        }
        let expected: [(Double, Int32)] = [
            (6, DOMINE_DEMO_SECTION_PING_PONG), (12, DOMINE_DEMO_SECTION_SWEEP),
            (18, DOMINE_DEMO_SECTION_ORBIT), (28, DOMINE_DEMO_SECTION_SWELL),
            (38, DOMINE_DEMO_SECTION_SILENCE), (39, DOMINE_DEMO_SECTION_DROP),
            (47, DOMINE_DEMO_SECTION_FINISHED),
        ]
        #expect(changes.count == expected.count)
        for (c, e) in zip(changes, expected) {
            #expect(c.0 == Self.frame(e.0, rate))
            #expect(c.1 == e.1)
        }
    }

    @Test func twoSpeakersGetDoubleHitsLeftThenRight() {
        let hits = Self.hits([30, -30]).filter { $0.section == DOMINE_DEMO_SECTION_ROLL_CALL }
        #expect(hits.count == 8)
        for (i, h) in hits.enumerated() {
            let slot = i / 2
            #expect(h.azimuth == (slot % 2 == 0 ? -30 : 30))
            #expect(h.frame == Self.frame(2 + Double(slot) + (i % 2 == 1 ? 0.25 : 0)))
            if i % 2 == 1 { #expect(h.gain > hits[i - 1].gain) }
        }
    }

    @Test func rollCallIsOneHitPerSpeakerPerRound() {
        let five = Self.hits([0, 110, -30, -90, 30]).filter { $0.section == DOMINE_DEMO_SECTION_ROLL_CALL }
        let order: [Float] = [-90, -30, 0, 30, 110]
        #expect(five.map(\.azimuth) == order + order)
        let nine = Self.hits((0..<9).map { Float($0) * 40 - 160 }).filter { $0.section == DOMINE_DEMO_SECTION_ROLL_CALL }
        #expect(nine.map(\.azimuth) == [-80, -40, 0, 40, 80, 120, 160, -160, -120])
    }

    @Test func pingPongAlternatesFromLeftAndAccelerates() {
        let hits = Self.hits(Self.stereo).filter { $0.section == DOMINE_DEMO_SECTION_PING_PONG }
        #expect(hits.count == 24)
        #expect(hits.first?.frame == Self.frame(6))
        for (i, h) in hits.enumerated() { #expect(h.azimuth == (i % 2 == 0 ? -90 : 90)) }
        let gaps = zip(hits.dropFirst(), hits).map { Double($0.frame - $1.frame) / Self.rate }
        for (a, b) in zip(gaps.dropFirst(), gaps) { #expect(a <= b + 1e-9) }
        #expect(abs(gaps[0] - 0.5) < 1e-9)
        #expect(abs(gaps[gaps.count - 1] - 0.125) < 1e-9)
    }

    @Test func silenceIsExactAndImpactHitsEverySpeaker() {
        var d = DomineDemo()
        domine_demo_reset(&d, Self.rate, 2, Self.stereo)
        var v = Self.voices()
        var silent = true
        var impacts: [Hit] = []
        for f in 0..<(Self.frame(47) + 500) {
            let s = domine_demo_tick(&d, &v)
            if s == DOMINE_DEMO_SECTION_SILENCE || s == DOMINE_DEMO_SECTION_FINISHED {
                silent = silent && v.allSatisfy { $0.sample == 0 }
            }
            if s == DOMINE_DEMO_SECTION_DROP, let h = Self.onset(d, f) { impacts.append(h) }
        }
        #expect(silent)
        #expect(impacts.count == 1)
        #expect(impacts.first?.frame == Self.frame(39))
        #expect(impacts.first?.omni == 1)
        #expect(abs(domine_demo_seconds(&d) - 47) < 1e-9)
    }

    @Test func peaksStayWithinLimitsAndFinite() {
        var d = DomineDemo()
        let az: [Float] = [-45, 45, 135, -135]
        domine_demo_reset(&d, Self.rate, 4, az)
        var v = Self.voices()
        var voicePeak: Float = 0
        var sumPeak: Float = 0
        var allFinite = true
        for _ in 0..<Self.frame(domine_demo_length(&d)) {
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
        #expect(voicePeak > 0.5)
        #expect(sumPeak <= 1.0)
    }

    @Test func twoResetsGiveIdenticalSamples() {
        var a = DomineDemo()
        var b = DomineDemo()
        domine_demo_reset(&a, Self.rate, 2, Self.stereo)
        domine_demo_reset(&b, 44100, 1, Self.stereo)
        var va = Self.voices()
        var vb = va
        for _ in 0..<50000 { _ = domine_demo_tick(&b, &vb) }
        domine_demo_reset(&b, Self.rate, 2, Self.stereo)
        var same = true
        for _ in 0..<Self.frame(47) {
            if domine_demo_tick(&a, &va) != domine_demo_tick(&b, &vb) { same = false }
            for i in 0..<va.count where va[i].sample != vb[i].sample || va[i].azimuth != vb[i].azimuth
                || va[i].omni != vb[i].omni {
                same = false
            }
        }
        #expect(same)
    }
}
