import CoreAudio
import DomineDSP
import Foundation
import Testing
@testable import Domine

/// Tap format matching, the default output's rate, and diagnostics.
@MainActor
struct EngineFormatTests {
    static let gripA = FakeHAL.Device(uid: "60-FD-A6-19-4F-2A:output", name: "JBL Grip",
                                      availableSampleRates: [48_000...48_000])
    static let gripB = FakeHAL.Device(uid: "60-FD-A6-19-9C-11:output", name: "JBL Grip",
                                      availableSampleRates: [48_000...48_000])
    static let speakers = FakeHAL.Device(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                                         transportType: kAudioDeviceTransportTypeBuiltIn,
                                         sampleRate: 44_100,
                                         availableSampleRates: [44_100...44_100, 48_000...48_000, 88_200...88_200, 96_000...96_000])

    let hal = FakeHAL()
    let engine: Engine

    init() {
        engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero,
                        diagnosticsInterval: .seconds(3600), formatCheckDelay: .seconds(3600))
    }

    private func start(defaultOutput: FakeHAL.Device? = speakers) async {
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        if let defaultOutput {
            hal.add(defaultOutput)
            hal.setDefault(uid: defaultOutput.uid)
        }
        await engine.start(left: Self.gripA.uid, right: Self.gripB.uid)
    }

    @Test func defaultOutputIsSetToTheSpeakersRateAndRestored() async {
        await start()
        #expect(engine.state == .running)
        #expect(hal.ops.contains(.setSampleRate(uid: Self.speakers.uid)))
        #expect(hal.sampleRate(uid: Self.speakers.uid) == 48_000)
        #expect(engine.inputFormat == Engine.InputFormat(sampleRate: 48_000, channels: 2, nonInterleaved: false))
        engine.stop()
        #expect(hal.sampleRate(uid: Self.speakers.uid) == 44_100)
    }

    @Test func unsupportedRateIsLeftAloneAndStillStarts() async {
        var odd = Self.speakers
        odd.availableSampleRates = [44_100...44_100]
        await start(defaultOutput: odd)
        #expect(engine.state == .running)
        #expect(!hal.ops.contains(.setSampleRate(uid: odd.uid)))
        #expect(engine.inputFormat?.sampleRate == 44_100)
    }

    @Test func rangeOfRatesCountsAsSupported() async {
        var ranged = Self.speakers
        ranged.availableSampleRates = [8_000...96_000]
        await start(defaultOutput: ranged)
        #expect(hal.sampleRate(uid: ranged.uid) == 48_000)
    }

    @Test func speakerAsDefaultOutputIsNotTouched() async {
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        hal.setDefault(uid: Self.gripA.uid)
        await engine.start(left: Self.gripA.uid, right: Self.gripB.uid)
        #expect(engine.state == .running)
        #expect(hal.ops.filter { $0 == .setSampleRate(uid: Self.gripA.uid) }.isEmpty)
    }

    @Test func nonInterleavedTapReachesTheKernel() async {
        hal.tapStreams = [1, 1]
        hal.tapNonInterleaved = true
        await start()
        #expect(engine.inputFormat == Engine.InputFormat(sampleRate: 48_000, channels: 2, nonInterleaved: true))
        let input = FakeBufferList(channelsPerBuffer: [1, 1], frames: 4)
        input.set(buffer: 0, channel: 0, [0.1, 0.2, 0.3, 0.4])
        input.set(buffer: 1, channel: 0, [-0.1, -0.2, -0.3, -0.4])
        let out = FakeBufferList(channelsPerBuffer: [2, 2], frames: 4, fill: 9)
        hal.render(input: input, output: out)
        #expect(out.channel(0) == [0.1, 0.2, 0.3, 0.4])
        #expect(out.channel(3) == [-0.1, -0.2, -0.3, -0.4])
    }

    @Test func formatChangeWhileRunningRebuilds() async {
        await start()
        let tapsBefore = hal.ops.filter { if case .createTap = $0 { true } else { false } }.count
        hal.setDefault(uid: Self.gripA.uid) // default output moved to a Grip
        #expect(await engine.checkFormat())
        #expect(engine.state == .running)
        let tapsAfter = hal.ops.filter { if case .createTap = $0 { true } else { false } }.count
        #expect(tapsAfter == tapsBefore + 1)
        // The previous default output got its own rate back.
        #expect(hal.sampleRate(uid: Self.speakers.uid) == 44_100)
        // Nothing changed since: no further rebuild.
        #expect(await engine.checkFormat() == false)
    }

    @Test func stopRemovesWatchersAndDiagnosticsListener() async {
        let baseline = hal.listenerCount
        await start()
        #expect(hal.listenerCount > baseline)
        engine.stop()
        #expect(hal.listenerCount == baseline)
    }

    @Test func diagnosticsCountOverloadsAndMeasureRates() async throws {
        await start()
        let diagnostics = try #require(engine.diagnostics)
        let aggregate = try #require(hal.id(forUID: hal.lastAggregateDescription?[kAudioAggregateDeviceUIDKey] as? String ?? ""))
        hal.fire(.processorOverload(aggregate))
        hal.fire(.processorOverload(aggregate))
        #expect(diagnostics.overloads == 2)

        // Two cycles 1 s of host time apart at 48 kHz.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksPerSecond = UInt64(1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
        for (index, host) in [UInt64(1_000), 1_000 + ticksPerSecond].enumerated() {
            let input = FakeBufferList(channelsPerBuffer: [2], frames: 512)
            let out = FakeBufferList(channelsPerBuffer: [2, 2], frames: 512)
            let sample = Double(index) * 48_000
            hal.render(input: input, output: out,
                       now: Self.stamp(host: host, sample: sample),
                       inputTime: Self.stamp(host: host, sample: sample),
                       outputTime: Self.stamp(host: host, sample: sample + 1_024))
            if index == 0 { diagnostics.sample() }
        }
        let window = diagnostics.sample()
        #expect(window.cycles == 1)
        #expect(window.frames == 512)
        #expect(window.inputFrames == 512)
        #expect(abs((window.effectiveSampleRate ?? 0) - 48_000) < 0.5)
        #expect(window.ioGapFrames == 1_024)
        #expect(window.underrunFrames == 0)
    }

    static func stamp(host: UInt64, sample: Double) -> AudioTimeStamp {
        var t = AudioTimeStamp()
        t.mHostTime = host
        t.mSampleTime = sample
        t.mFlags = [.hostTimeValid, .sampleTimeValid]
        return t
    }
}

struct DiagnosticsWindowTests {
    static func stats(cycles: UInt64, frames: UInt64, host: UInt64, outSample: Double, inSample: Double) -> DomineKernelStats {
        var s = DomineKernelStats()
        s.cycles = cycles
        s.frames = frames
        s.inputFrames = frames
        s.nowHostTime = host
        s.inputHostTime = host - 100
        s.outputHostTime = host + 200
        s.outputSampleTime = outSample
        s.inputSampleTime = inSample
        s.timeFlags = 0x1F
        return s
    }

    @Test func exactRates() {
        // 1 tick = 1 microsecond; 2 s window, 187.5 cycles/s of 256 frames.
        let p = Self.stats(cycles: 10, frames: 2_560, host: 1_000_000, outSample: 0, inSample: -1_000)
        var c = Self.stats(cycles: 385, frames: 98_560, host: 3_000_000, outSample: 96_000, inSample: 95_000)
        c.underrunFrames = 7
        c.maxCycleInterval = 6_000
        let w = DiagnosticsWindow.compute(previous: p, current: c, secondsPerTick: 1e-6)
        #expect(w.seconds == 2)
        #expect(w.cycles == 375)
        #expect(w.cyclesPerSecond == 187.5)
        #expect(w.framesPerSecond == 48_000)
        #expect(w.inputFramesPerSecond == 48_000)
        #expect(w.effectiveSampleRate == 48_000)
        #expect(w.effectiveInputSampleRate == 48_000)
        #expect(w.ioGapFrames == 1_000)
        #expect(abs((w.outputLeadMs ?? 0) - 0.2) < 1e-9)
        #expect(abs((w.inputLagMs ?? 0) - 0.1) < 1e-9)
        #expect(w.maxCycleIntervalMs == 6)
        #expect(w.underrunFrames == 7)
    }

    @Test func slowClockShowsUp() {
        let p = Self.stats(cycles: 0, frames: 0, host: 1_000_000, outSample: 0, inSample: 0)
        let c = Self.stats(cycles: 1, frames: 0, host: 2_000_000, outSample: 44_100, inSample: 44_100)
        #expect(DiagnosticsWindow.compute(previous: p, current: c, secondsPerTick: 1e-6).effectiveSampleRate == 44_100)
    }

    @Test func invalidTimesGiveNoRates() {
        var p = Self.stats(cycles: 0, frames: 0, host: 1_000, outSample: 0, inSample: 0)
        var c = Self.stats(cycles: 4, frames: 4, host: 2_000, outSample: 1, inSample: 1)
        p.timeFlags = 0
        c.timeFlags = 0
        let w = DiagnosticsWindow.compute(previous: p, current: c, secondsPerTick: 1)
        #expect(w.seconds == nil)
        #expect(w.effectiveSampleRate == nil)
        #expect(w.ioGapFrames == nil)
        #expect(w.cycles == 4)
    }
}
