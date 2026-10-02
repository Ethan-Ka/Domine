import CoreAudio
import Foundation
import Testing
@testable import Domine

/// A speaker leaving and returning while routing (SPEC section 7).
@MainActor
final class MonoFallbackTests {
    static let gripA = EngineTests.gripA
    static let gripB = EngineTests.gripB
    /// 50 ms at the Grips' 44.1 kHz.
    static let fade = 2205

    let hal = FakeHAL()
    var engine: Engine!
    /// Every fade wait the engine asked for, in order.
    var fadeWaits: [Duration] = []
    /// What the old aggregate played while the engine waited out each fade.
    var fadeOutRenders: [FakeBufferList] = []
    /// Runs inside the fade wait, e.g. to stop the engine mid-rebuild.
    var duringFade: (@MainActor () -> Void)?
    var routingEnded = 0

    init() {
        engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero, fadeWait: { [unowned self] wait in
            self.fadeWaits.append(wait)
            self.fadeOutRenders.append(self.render(output: self.engine.layout.map(Self.outputShape) ?? [2, 2]))
            self.duringFade?()
        })
        engine.onRoutingEnded = { [unowned self] in self.routingEnded += 1 }
    }

    // MARK: Helpers

    private func startGrips() async {
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        await engine.start(left: Self.gripA.uid, right: Self.gripB.uid)
        #expect(engine.state == .running)
    }

    /// Lets the speaker check the HAL listener started run to the end.
    private func settle() async {
        await engine.speakerCheck?.value
    }

    /// Output buffers of the running aggregate: one stereo buffer per speaker.
    private static func outputShape(_ layout: AggregateLayout) -> [Int] {
        [layout.outAChannelOffset, layout.outBChannelOffset].compactMap { $0 }.map { _ in 2 }
    }

    /// One cycle of constant L and R through the running IOProc.
    private func render(output: [Int], frames: Int = 3000, left: Float = 0.5, right: Float = 0.25) -> FakeBufferList {
        let input = FakeBufferList(channelsPerBuffer: [2], frames: frames)
        input.set(buffer: 0, channel: 0, Array(repeating: left, count: frames))
        input.set(buffer: 0, channel: 1, Array(repeating: right, count: frames))
        let out = FakeBufferList(channelsPerBuffer: output, frames: frames, fill: 9)
        hal.render(input: input, output: out)
        return out
    }

    private static func fadingOut(_ value: Float, frames: Int = 3000) -> [Float] {
        (0..<frames).map { value * (Float(max(0, fade - ($0 + 1))) / Float(fade)) }
    }

    private static func fadingIn(_ value: Float, frames: Int = 3000) -> [Float] {
        (0..<frames).map { value * (Float(min(fade, $0 + 1)) / Float(fade)) }
    }

    private var subDeviceUIDs: [String] {
        (hal.lastAggregateDescription?[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? [])
            .compactMap { $0[kAudioSubDeviceUIDKey] as? String }
    }

    static let rebuildOps: [FakeHAL.Op] = [
        .stop, .destroyIOProc, .destroyAggregate, .destroyTap,
        .createTap(excluding: [42]), .createAggregate, .createIOProc, .start,
    ]

    // MARK: One speaker leaves

    @Test func rightSpeakerLeavingRebuildsWithLeftInMono() async {
        await startGrips()
        let before = hal.ops.count
        hal.remove(uid: Self.gripB.uid)
        await settle()

        #expect(engine.state == .degraded(.monoFallback(missing: .right)))
        #expect(engine.state.isActive)
        #expect(Array(hal.ops.dropFirst(before)) == Self.rebuildOps)
        #expect(hal.liveTapCount == 1)
        #expect(hal.liveAggregateCount == 1)
        #expect(subDeviceUIDs == [Self.gripA.uid])
        #expect(engine.layout == AggregateLayout(inFirstBuffer: 0, tapBuffers: 1, outAChannelOffset: 0, outBChannelOffset: nil))
        #expect(fadeWaits == [Engine.rebuildFadeWait])
    }

    @Test func fadesOutTheOldAggregateAndFadesInMono() async throws {
        await startGrips()
        hal.remove(uid: Self.gripB.uid)
        await settle()

        // During the wait the old aggregate (both speakers) ramps to silence.
        let old = try #require(fadeOutRenders.first)
        #expect(old.channel(0) == Self.fadingOut(0.5))
        #expect(old.channel(1) == Self.fadingOut(0.5))
        #expect(old.channel(2) == Self.fadingOut(0.25))
        #expect(old.channel(3) == Self.fadingOut(0.25))

        // The new kernel starts silent and ramps (L + R) / 2 up on both channels.
        let mono = render(output: [2])
        #expect(mono.channel(0) == Self.fadingIn(0.375))
        #expect(mono.channel(1) == Self.fadingIn(0.375))
    }

    @Test func leftSpeakerLeavingKeepsRightOnPositionB() async {
        await startGrips()
        hal.remove(uid: Self.gripA.uid)
        await settle()

        #expect(engine.state == .degraded(.monoFallback(missing: .left)))
        #expect(subDeviceUIDs == [Self.gripB.uid])
        #expect(engine.layout == AggregateLayout(inFirstBuffer: 0, tapBuffers: 1, outAChannelOffset: nil, outBChannelOffset: 0))
        let mono = render(output: [2])
        #expect(mono.channel(0) == Self.fadingIn(0.375))
        #expect(mono.channel(1) == Self.fadingIn(0.375))
        let (peakA, peakB) = engine.peaks()
        #expect(peakA == 0)
        #expect(peakB == 0.375)
    }

    @Test func monoFallbackIgnoresSwap() async {
        await startGrips()
        engine.swapSides = true
        hal.remove(uid: Self.gripB.uid)
        await settle()
        let mono = render(output: [2])
        #expect(mono.channel(0) == Self.fadingIn(0.375))
    }

    @Test func notAliveCountsAsGone() async {
        await startGrips()
        hal.setAlive(uid: Self.gripB.uid, false)
        await settle()
        #expect(engine.state == .degraded(.monoFallback(missing: .right)))
        #expect(subDeviceUIDs == [Self.gripA.uid])

        hal.setAlive(uid: Self.gripB.uid, true)
        await settle()
        #expect(engine.state == .running)
        #expect(subDeviceUIDs == [Self.gripA.uid, Self.gripB.uid])
    }

    @Test func otherDeviceChangesDoNotRebuild() async {
        await startGrips()
        let before = hal.ops.count
        hal.add(FakeHAL.Device(uid: "USB-DAC-1", name: "USB DAC", transportType: kAudioDeviceTransportTypeUSB))
        await settle()
        #expect(engine.state == .running)
        #expect(hal.ops.count == before)
        #expect(fadeWaits.isEmpty)
    }

    // MARK: The speaker returns

    @Test func returningSpeakerRestoresStereo() async throws {
        await startGrips()
        hal.remove(uid: Self.gripB.uid)
        await settle()
        _ = render(output: [2]) // past the mono fade in
        let before = hal.ops.count
        hal.add(Self.gripB)
        await settle()

        #expect(engine.state == .running)
        #expect(Array(hal.ops.dropFirst(before)) == Self.rebuildOps)
        #expect(hal.liveTapCount == 1)
        #expect(hal.liveAggregateCount == 1)
        #expect(subDeviceUIDs == [Self.gripA.uid, Self.gripB.uid])
        #expect(engine.layout?.outAChannelOffset == 0)
        #expect(engine.layout?.outBChannelOffset == 2)
        #expect(fadeWaits == [Engine.rebuildFadeWait, Engine.rebuildFadeWait])

        // The mono aggregate fades out, then stereo fades in.
        let mono = try #require(fadeOutRenders.last)
        #expect(mono.channel(0) == Self.fadingOut(0.375))
        let stereo = render(output: [2, 2])
        #expect(stereo.channel(0) == Self.fadingIn(0.5))
        #expect(stereo.channel(1) == Self.fadingIn(0.5))
        #expect(stereo.channel(2) == Self.fadingIn(0.25))
        #expect(stereo.channel(3) == Self.fadingIn(0.25))
    }

    @Test func returningLeftSpeakerRestoresStereo() async {
        await startGrips()
        hal.remove(uid: Self.gripA.uid)
        await settle()
        hal.add(Self.gripA)
        await settle()
        #expect(engine.state == .running)
        // Device A is the main sub-device again.
        #expect(subDeviceUIDs == [Self.gripA.uid, Self.gripB.uid])
    }

    @Test func failedStereoRebuildStaysInMono() async {
        await startGrips()
        hal.remove(uid: Self.gripB.uid)
        await settle()
        // Back with an input stream: the engine refuses to open it.
        var withMic = Self.gripB
        withMic.inputStreams = [1]
        hal.add(withMic)
        await settle()
        #expect(engine.state == .degraded(.monoFallback(missing: .right)))
        #expect(subDeviceUIDs == [Self.gripA.uid])
        #expect(hal.liveAggregateCount == 1)
        #expect(routingEnded == 0)
        #expect(fadeWaits.count == 2) // not retried in a loop
    }

    // MARK: Both gone

    @Test func bothSpeakersGoneStops() async {
        await startGrips()
        hal.remove(uid: Self.gripB.uid)
        await settle()
        hal.remove(uid: Self.gripA.uid)
        await settle()

        #expect(engine.state == .idle)
        #expect(engine.idleReason == .speakersDisconnected)
        #expect(routingEnded == 1)
        #expect(hal.liveTapCount == 0)
        #expect(hal.liveAggregateCount == 0)
        #expect(hal.liveIOProcCount == 0)
        #expect(!engine.isKernelAllocated)
    }

    @Test func bothSpeakersGoneAtOnceStopsWithoutRebuilding() async {
        await startGrips()
        let before = hal.ops.count
        hal.remove(uid: Self.gripA.uid)
        hal.remove(uid: Self.gripB.uid)
        await settle()
        #expect(engine.state == .idle)
        #expect(Array(hal.ops.dropFirst(before)) == [.stop, .destroyIOProc, .destroyAggregate, .destroyTap])
        #expect(routingEnded == 1)
    }

    @Test func stopDuringTheFadeCancelsTheRebuild() async {
        await startGrips()
        duringFade = { [unowned self] in self.engine.stop() }
        let before = hal.ops.count
        hal.remove(uid: Self.gripB.uid)
        await settle()
        #expect(engine.state == .idle)
        #expect(Array(hal.ops.dropFirst(before)) == [.stop, .destroyIOProc, .destroyAggregate, .destroyTap])
        #expect(routingEnded == 0)
    }

    @Test func stoppedEngineIgnoresDeviceChanges() async {
        await startGrips()
        engine.stop()
        let before = hal.ops.count
        hal.remove(uid: Self.gripB.uid)
        await settle()
        #expect(engine.state == .idle)
        #expect(hal.ops.count == before)
    }
}
