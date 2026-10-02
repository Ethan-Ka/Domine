import CoreAudio
import DomineDSP
import Testing

struct SpatialTests {
    static let rate = 48000.0

    static func render(_ sp: OpaquePointer, _ l: [Float], _ r: [Float]) -> ([Float], [Float]) {
        var rl = [Float](repeating: 9, count: l.count)
        var rr = rl
        domine_spatial_process(sp, l, r, &rl, &rr, UInt32(l.count))
        return (rl, rr)
    }

    static func noise(_ n: Int, seed: UInt32 = 1, scale: Float = 1) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 1664525 &+ 1013904223
            return (Float(s >> 8) / Float(1 << 24) * 2 - 1) * scale
        }
    }

    static func settle(_ sp: OpaquePointer, amount: Float, room: Float = 15) {
        var p = DomineSpatialParams(amount: amount, roomMs: room, highCutHz: 5000)
        domine_spatial_set_params(sp, &p)
        _ = render(sp, [Float](repeating: 0, count: 24000), [Float](repeating: 0, count: 24000))
    }

    @Test func amountZeroIsBitExactMirror() {
        let sp = domine_spatial_create(Self.rate)!
        defer { domine_spatial_destroy(sp) }
        let l = Self.noise(2000, seed: 3), r = Self.noise(2000, seed: 7)
        let (rl, rr) = Self.render(sp, l, r)
        #expect(rl == l)
        #expect(rr == r)
        #expect(domine_spatial_is_idle(sp) != 0)
    }

    @Test func amountZeroAfterRampIsBitExact() {
        let sp = domine_spatial_create(Self.rate)!
        defer { domine_spatial_destroy(sp) }
        Self.settle(sp, amount: 1)
        _ = Self.render(sp, Self.noise(1000), Self.noise(1000, seed: 5))
        Self.settle(sp, amount: 0)
        let l = Self.noise(500, seed: 9), r = Self.noise(500, seed: 11)
        let (rl, rr) = Self.render(sp, l, r)
        #expect(rl == l)
        #expect(rr == r)
    }

    @Test func monoInputGivesSilentRears() {
        let sp = domine_spatial_create(Self.rate)!
        defer { domine_spatial_destroy(sp) }
        Self.settle(sp, amount: 1)
        let m = Self.noise(4000)
        let (rl, rr) = Self.render(sp, m, m)
        #expect(rl.allSatisfy { abs($0) < 1e-6 })
        #expect(rr.allSatisfy { abs($0) < 1e-6 })
    }

    @Test func sideOnlyInputAppearsInRears() {
        let sp = domine_spatial_create(Self.rate)!
        defer { domine_spatial_destroy(sp) }
        Self.settle(sp, amount: 1, room: 5)
        let s = Self.noise(4800, scale: 0.5)
        let (rl, rr) = Self.render(sp, s, s.map { -$0 })
        let el = rl.suffix(2400).reduce(0) { $0 + $1 * $1 }
        let er = rr.suffix(2400).reduce(0) { $0 + $1 * $1 }
        #expect(el > 100 && er > 100)
        // Decorrelated: the two rears are not the same signal.
        let dot = zip(rl, rr).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        #expect(abs(dot) < 0.5 * (el + er) / 2 * 2)
    }

    @Test func rearDelayFollowsRoomSize() {
        let sp = domine_spatial_create(Self.rate)!
        defer { domine_spatial_destroy(sp) }
        Self.settle(sp, amount: 1, room: 30)
        var l = [Float](repeating: 0, count: 4800)
        l[0] = 1
        let (rl, _) = Self.render(sp, l, l.map { -$0 })
        let first = rl.firstIndex { abs($0) > 1e-4 }!
        // 30 ms is 1440 samples; the all-pass chain adds its own early taps.
        #expect(first >= 1440 && first < 1440 + 4)
    }

    @Test func peakBoundAndNoNaN() {
        let sp = domine_spatial_create(Self.rate)!
        defer { domine_spatial_destroy(sp) }
        Self.settle(sp, amount: 0.7)
        var l = Self.noise(48000, seed: 21), r = Self.noise(48000, seed: 22)
        l = l.enumerated().map { $0.offset % 97 < 48 ? 1 : $0.element }
        r = r.enumerated().map { $0.offset % 97 < 48 ? -1 : $0.element }
        let (rl, rr) = Self.render(sp, l, r)
        #expect((rl + rr).allSatisfy { $0.isFinite && abs($0) <= 1.0 })
    }

    @Test func parameterChangesAreSmooth() {
        let sp = domine_spatial_create(Self.rate)!
        defer { domine_spatial_destroy(sp) }
        let l = [Float](repeating: 0.5, count: 4800), r = [Float](repeating: -0.5, count: 4800)
        _ = Self.render(sp, l, r)
        _ = Self.render(sp, l, r)
        var p = DomineSpatialParams(amount: 1, roomMs: 15, highCutHz: 5000)
        domine_spatial_set_params(sp, &p)
        let (rl, _) = Self.render(sp, l, r)
        var maxStep: Float = 0
        for i in 1..<rl.count { maxStep = max(maxStep, abs(rl[i] - rl[i - 1])) }
        // Mirror is 0.5; a hard switch would step by 0.5 at once.
        #expect(maxStep < 0.01)
        #expect(rl[0] != 0.5 || rl[1] != 0.5)
    }

    @Test func invalidParamsAreClamped() {
        let sp = domine_spatial_create(Self.rate)!
        defer { domine_spatial_destroy(sp) }
        var p = DomineSpatialParams(amount: .nan, roomMs: .infinity, highCutHz: -5)
        domine_spatial_set_params(sp, &p)
        let l = Self.noise(1000), r = Self.noise(1000, seed: 2)
        let (rl, rr) = Self.render(sp, l, r)
        #expect(rl == l && rr == r)
    }

    @Test func quadHookAmountZeroEqualsMirror() {
        let q = domine_quad_create(48000, 256)!
        defer { domine_quad_destroy(q) }
        domine_quad_set_rear_mode(q, Int32(DOMINE_REAR_SPATIAL))
        domine_quad_set_rear_trim(q, 0.5)
        let out = QuadKernelTests.run(q, offsets: QuadKernelTests.full)
        #expect(out.channel(0) == QuadKernelTests.left)
        #expect(out.channel(4) == QuadKernelTests.left.map { $0 * 0.5 })
        #expect(out.channel(6) == QuadKernelTests.right.map { $0 * 0.5 })
    }

    @Test func quadHookSideInputReachesRears() {
        let q = domine_quad_create(48000, 4800)!
        defer { domine_quad_destroy(q) }
        domine_quad_set_rear_mode(q, Int32(DOMINE_REAR_SPATIAL))
        var p = DomineSpatialParams(amount: 1, roomMs: 5, highCutHz: 5000)
        domine_quad_set_spatial(q, &p)
        let s = Self.noise(4800, scale: 0.5)
        var peak: Float = 0
        for _ in 0..<3 {
            let out = QuadKernelTests.run(q, offsets: QuadKernelTests.full, left: s, right: s.map { -$0 }, buffers: [8])
            peak = max(peak, out.channel(4).map { abs($0) }.max() ?? 0)
            #expect(out.channel(0) == s)
        }
        #expect(peak > 0.1)
    }
}
