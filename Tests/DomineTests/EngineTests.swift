import CoreAudio
import Foundation
import Testing
@testable import Domine

@MainActor
struct EngineTests {
    nonisolated static let gripA = FakeHAL.Device(uid: "60-FD-A6-19-4F-2A:output", name: "JBL Grip", sampleRate: 44_100)
    nonisolated static let gripB = FakeHAL.Device(uid: "60-FD-A6-19-9C-11:output", name: "JBL Grip", sampleRate: 44_100)

    static let left: [Float] = [0.1, 0.2, 0.3, 0.4]
    static let right: [Float] = [-0.1, -0.2, -0.3, -0.4]

    let hal = FakeHAL()
    let engine: Engine

    init() {
        engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero)
    }

    static let startOps: [FakeHAL.Op] = [
        .setSampleRate(uid: gripA.uid), .setSampleRate(uid: gripB.uid),
        .createTap(excluding: [42]), .createAggregate, .createIOProc, .start,
    ]

    private func startGrips(_ a: FakeHAL.Device = gripA, _ b: FakeHAL.Device = gripB) async {
        hal.add(a)
        hal.add(b)
        await engine.start(left: a.uid, right: b.uid)
    }

    private func expectNothingLive(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(hal.liveTapCount == 0, sourceLocation: sourceLocation)
        #expect(hal.liveAggregateCount == 0, sourceLocation: sourceLocation)
        #expect(hal.liveIOProcCount == 0, sourceLocation: sourceLocation)
        #expect(!hal.isRunning, sourceLocation: sourceLocation)
        #expect(!engine.isKernelAllocated, sourceLocation: sourceLocation)
    }

    /// Renders one cycle with stereo tap input placed after `subInputs` sub-device buffers.
    private func render(output: [Int], subInputs: [Int] = [], tap: [Int] = [2]) -> FakeBufferList {
        let input = FakeBufferList(channelsPerBuffer: subInputs + tap, frames: Self.left.count, fill: 0.9)
        if tap == [2] {
            input.set(buffer: subInputs.count, channel: 0, Self.left)
            input.set(buffer: subInputs.count, channel: 1, Self.right)
        } else {
            input.set(buffer: subInputs.count, channel: 0, Self.left)
            input.set(buffer: subInputs.count + 1, channel: 0, Self.right)
        }
        let out = FakeBufferList(channelsPerBuffer: output, frames: Self.left.count, fill: 9)
        hal.render(input: input, output: out)
        return out
    }

    // MARK: - Start and stop order

    @Test func startCreatesInOrder() async {
        await startGrips()
        #expect(engine.state == .running)
        #expect(hal.ops == Self.startOps)
        #expect(hal.isRunning)
        #expect(engine.isKernelAllocated)
        #expect(hal.sampleRate(uid: Self.gripA.uid) == 48_000)
    }

    @Test func stopTearsDownInReverse() async {
        await startGrips()
        engine.stop()
        #expect(engine.state == .idle)
        #expect(Array(hal.ops.dropFirst(Self.startOps.count)) == [.stop, .destroyIOProc, .destroyAggregate, .destroyTap])
        #expect(engine.layout == nil)
        expectNothingLive()
    }

    @Test func tapExcludesOwnProcess() async {
        hal.ownProcess = 777
        await startGrips()
        #expect(hal.ops.contains(.createTap(excluding: [777])))
    }

    @Test func startWhileRunningDoesNothing() async {
        await startGrips()
        await engine.start(left: Self.gripA.uid, right: Self.gripB.uid)
        #expect(hal.ops == Self.startOps)
    }

    @Test func noSampleRateChangeWhenAlready48k() async {
        var a = Self.gripA, b = Self.gripB
        a.sampleRate = 48_000
        b.sampleRate = 48_000
        await startGrips(a, b)
        #expect(hal.ops == Array(Self.startOps.dropFirst(2)))
    }

    @Test func sampleRateFailureIsOnlyAWarning() async {
        hal.failures[.setSampleRate] = kAudioHardwareIllegalOperationError
        await startGrips()
        #expect(engine.state == .running)
    }

    // MARK: - Failure unwinding

    nonisolated static let unwindCases: [(FakeHAL.FailPoint, [FakeHAL.Op])] = [
        (.ownProcess, []),
        (.createTap, []),
        (.tapFormat, [.createTap(excluding: [42]), .destroyTap]),
        (.createAggregate, [.createTap(excluding: [42]), .destroyTap]),
        (.aggregateStreams, [.createTap(excluding: [42]), .createAggregate, .destroyAggregate, .destroyTap]),
        (.createIOProc, [.createTap(excluding: [42]), .createAggregate, .destroyAggregate, .destroyTap]),
        (.start, [.createTap(excluding: [42]), .createAggregate, .createIOProc,
                  .destroyIOProc, .destroyAggregate, .destroyTap]),
    ]

    @Test(arguments: 0..<unwindCases.count)
    func failureUnwindsWhatWasCreated(index: Int) async {
        let (point, expected) = Self.unwindCases[index]
        hal.failures[point] = kAudioHardwareUnspecifiedError
        await startGrips()
        guard case .error(let message) = engine.state else {
            Issue.record("expected error state for \(point), got \(engine.state)")
            return
        }
        #expect(message.contains("'what'"))
        #expect(Array(hal.ops.dropFirst(2)) == expected, "fail point \(point)")
        expectNothingLive()
    }

    @Test func streamUsageFailureUnwinds() async {
        var a = Self.gripA
        a.transportType = kAudioDeviceTransportTypeUSB
        a.inputStreams = [1]
        hal.failures[.setStreamUsage] = kAudioHardwareUnspecifiedError
        await startGrips(a)
        #expect(Array(hal.ops.dropFirst(2)) == [
            .createTap(excluding: [42]), .createAggregate, .createIOProc,
            .destroyIOProc, .destroyAggregate, .destroyTap,
        ])
        expectNothingLive()
    }

    @Test func missingOwnProcessObjectFails() async {
        hal.ownProcess = kAudioObjectUnknown
        await startGrips()
        #expect(engine.state == .error(EngineError.noOwnProcessObject.description))
        #expect(hal.liveTapCount == 0)
    }

    @Test func canStartAgainAfterError() async {
        hal.failures[.start] = kAudioHardwareUnspecifiedError
        await startGrips()
        hal.failures = [:]
        await engine.start(left: Self.gripA.uid, right: Self.gripB.uid)
        #expect(engine.state == .running)
    }

    @Test func stopClearsError() async {
        hal.failures[.createTap] = kAudioHardwareUnspecifiedError
        await startGrips()
        engine.stop()
        #expect(engine.state == .idle)
    }

    // MARK: - Refusals

    @Test func refusesMissingSelection() async {
        hal.add(Self.gripA)
        await engine.start(left: Self.gripA.uid, right: nil)
        #expect(engine.state == .idle)
        #expect(engine.idleReason == .noRightSpeaker)
        await engine.start(left: nil, right: Self.gripA.uid)
        #expect(engine.idleReason == .noLeftSpeaker)
        #expect(hal.ops.isEmpty)
    }

    @Test func refusesDisconnectedDevices() async {
        hal.add(Self.gripA)
        await engine.start(left: Self.gripA.uid, right: Self.gripB.uid)
        #expect(engine.idleReason == .rightMissing)
        await engine.start(left: Self.gripB.uid, right: Self.gripA.uid)
        #expect(engine.idleReason == .leftMissing)
        #expect(engine.state == .idle)
        #expect(hal.ops.isEmpty)
    }

    @Test func refusesSameDevice() async {
        hal.add(Self.gripA)
        await engine.start(left: Self.gripA.uid, right: Self.gripA.uid)
        #expect(engine.state == .idle)
        #expect(engine.idleReason == .sameSpeaker)
        #expect(hal.ops.isEmpty)
    }

    @Test func refusesBluetoothDeviceWithInputStreams() async {
        var b = Self.gripB
        b.inputStreams = [1]
        await startGrips(Self.gripA, b)
        #expect(engine.state == .error(EngineError.bluetoothInput(uid: b.uid).description))
        #expect(hal.ops.isEmpty)
    }

    // MARK: - Aggregate description

    @Test func aggregateDescriptionIsPrivateWithAAsMain() async throws {
        await startGrips()
        let description = try #require(hal.lastAggregateDescription)
        #expect(description[kAudioAggregateDeviceIsPrivateKey] as? Int == 1)
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == Self.gripA.uid)
        #expect(description[kAudioAggregateDeviceClockDeviceKey] as? String == Self.gripA.uid)
        let uid = try #require(description[kAudioAggregateDeviceUIDKey] as? String)
        #expect(uid.hasPrefix(DeviceCatalog.domineUIDPrefix + "aggregate."))
        let subs = try #require(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(subs.map { $0[kAudioSubDeviceUIDKey] as? String } == [Self.gripA.uid, Self.gripB.uid])
        #expect(subs.map { $0[kAudioSubDeviceDriftCompensationKey] as? Int } == [0, 1])
        let taps = try #require(description[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        #expect(taps.count == 1)
        #expect(taps.first?[kAudioSubTapDriftCompensationKey] as? Int == 1)
        #expect(taps.first?[kAudioSubTapUIDKey] as? String != nil)
    }

    // MARK: - Layout and rendering

    @Test func stereoStreamsLayoutAndRender() async {
        await startGrips()
        #expect(engine.layout == AggregateLayout(inFirstBuffer: 0, tapBuffers: 1, outAChannelOffset: 0, outBChannelOffset: 2))
        let out = render(output: [2, 2])
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == Self.right)
    }

    @Test func monoStreamsLayoutAndRender() async {
        var a = Self.gripA, b = Self.gripB
        a.outputStreams = [1, 1]
        b.outputStreams = [1, 1]
        await startGrips(a, b)
        #expect(engine.layout?.outBChannelOffset == 2)
        let out = render(output: [1, 1, 1, 1])
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == Self.right)
        #expect(out.channel(3) == Self.right)
    }

    @Test func unevenDevicesPlaceBAfterAllOfA() async {
        var a = Self.gripA
        a.transportType = kAudioDeviceTransportTypeUSB
        a.outputStreams = [1, 1, 1, 1]
        await startGrips(a)
        #expect(engine.layout?.outBChannelOffset == 4)
        let out = render(output: [1, 1, 1, 1, 2])
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(1) == Self.left)
        #expect(out.channel(2) == [0, 0, 0, 0])
        #expect(out.channel(3) == [0, 0, 0, 0])
        #expect(out.channel(4) == Self.right)
        #expect(out.channel(5) == Self.right)
    }

    @Test func nonBluetoothInputsAreDisabledAndSkipped() async {
        var a = Self.gripA
        a.transportType = kAudioDeviceTransportTypeUSB
        a.inputStreams = [2]
        await startGrips(a)
        #expect(engine.state == .running)
        #expect(hal.ops.contains(.setStreamUsage([false, true])))
        #expect(engine.layout?.inFirstBuffer == 1)
        let out = render(output: [2, 2], subInputs: [2])
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(2) == Self.right)
    }

    @Test func deinterleavedTapStreams() async {
        hal.tapStreams = [1, 1]
        await startGrips()
        #expect(engine.layout?.tapBuffers == 2)
        #expect(!hal.ops.contains { if case .setStreamUsage = $0 { true } else { false } })
        let out = render(output: [2, 2], tap: [1, 1])
        #expect(out.channel(0) == Self.left)
        #expect(out.channel(3) == Self.right)
    }

    @Test func layoutMismatchFailsAndUnwinds() async {
        hal.aggregateOutputOverride = [2]
        await startGrips()
        guard case .error(let message) = engine.state else {
            Issue.record("expected error, got \(engine.state)")
            return
        }
        #expect(message.contains("layout"))
        expectNothingLive()
    }

    @Test func waitsForAggregateToPublishStreams() async {
        hal.aggregateStreamsHiddenForAttempts = 2
        await startGrips()
        #expect(engine.state == .running)
        #expect(engine.layout?.outBChannelOffset == 2)
    }

    @Test func givesUpWhenStreamsNeverAppear() async {
        hal.aggregateStreamsHiddenForAttempts = 3
        await startGrips()
        guard case .error = engine.state else {
            Issue.record("expected error, got \(engine.state)")
            return
        }
        expectNothingLive()
    }

    @Test func stopWhileWaitingForStreamsCancelsStart() async {
        let slow = Engine(hal: hal, layoutAttempts: 50, layoutRetryDelay: .milliseconds(20))
        hal.aggregateStreamsHiddenForAttempts = 50
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        let task = Task { await slow.start(left: Self.gripA.uid, right: Self.gripB.uid) }
        while slow.state != .starting || hal.liveAggregateCount == 0 { await Task.yield() }
        slow.stop()
        await task.value
        #expect(slow.state == .idle)
        #expect(hal.liveTapCount == 0)
        #expect(hal.liveAggregateCount == 0)
        #expect(!hal.ops.contains(.createIOProc))
    }

    // MARK: - Controls

    @Test func swapAndToneReachTheKernel() async {
        await startGrips()
        engine.swapSides = true
        var out = render(output: [2, 2])
        #expect(out.channel(0) == Self.right)
        #expect(out.channel(2) == Self.left)

        engine.swapSides = false
        engine.testTone = .right
        out = render(output: [2, 2])
        #expect(out.channel(0) == [0, 0, 0, 0])
        #expect(out.channel(2) != [0, 0, 0, 0])
    }

    @Test func controlsSetBeforeStartApply() async {
        engine.swapSides = true
        engine.leftGain = 0.5
        await startGrips()
        let out = render(output: [2, 2])
        #expect(out.channel(0) == Self.right.map { $0 * 0.5 })
        #expect(out.channel(2) == Self.left)
    }
}
