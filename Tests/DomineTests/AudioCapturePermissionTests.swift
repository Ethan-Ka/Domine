import CoreAudio
import Foundation
import Testing
@testable import Domine

/// The capture permission probe against the fake HAL: what it creates, the
/// teardown order, unwinding on failure, and the status it reports.
@MainActor
final class AudioCapturePermissionTests {
    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let store: SettingsStore
    let permission: AudioCapturePermission

    static let probeOps: [FakeHAL.Op] = [
        .createTap(excluding: [42]), .createAggregate, .createIOProc, .start,
        .stop, .destroyIOProc, .destroyAggregate, .destroyTap,
    ]

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        store = SettingsStore(defaults: defaults)
        permission = AudioCapturePermission(hal: hal, store: store)
        permission.wait = {}
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    /// Makes the probe's wait run one IOProc cycle with this tap input.
    private func feed(_ value: Float) {
        permission.wait = { [hal] in
            let input = FakeBufferList(channelsPerBuffer: [2], frames: 4, fill: value)
            let output = FakeBufferList(channelsPerBuffer: [1], frames: 0)
            hal.render(input: input, output: output)
        }
    }

    private func expectNothingLive(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(hal.liveTapCount == 0, sourceLocation: sourceLocation)
        #expect(hal.liveAggregateCount == 0, sourceLocation: sourceLocation)
        #expect(hal.liveIOProcCount == 0, sourceLocation: sourceLocation)
        #expect(!hal.isRunning, sourceLocation: sourceLocation)
    }

    // MARK: Resources

    @Test func probeCreatesThenTearsDownInReverse() async throws {
        let heard = try await permission.capture()
        #expect(!heard)
        #expect(hal.ops == Self.probeOps)
        expectNothingLive()
    }

    @Test func tapDoesNotMute() async throws {
        _ = try await permission.capture()
        #expect(hal.tapMuteFlags == [false])
    }

    @Test func engineTapStillMutes() async {
        let engine = Engine(hal: hal, layoutAttempts: 1, layoutRetryDelay: .zero)
        hal.add(EngineTests.gripA)
        hal.add(EngineTests.gripB)
        await engine.start(left: EngineTests.gripA.uid, right: EngineTests.gripB.uid)
        #expect(hal.tapMuteFlags == [true])
        engine.stop()
    }

    @Test func aggregateIsPrivateAndHoldsOnlyTheTap() async throws {
        var description: [String: Any]?
        permission.wait = { [hal] in description = hal.lastAggregateDescription }
        _ = try await permission.capture()
        let d = try #require(description)
        #expect(d[kAudioAggregateDeviceIsPrivateKey] as? Int == 1)
        #expect(d[kAudioAggregateDeviceSubDeviceListKey] == nil)
        #expect(d[kAudioAggregateDeviceMainSubDeviceKey] == nil)
        let taps = try #require(d[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        #expect(taps.count == 1)
        #expect((taps[0][kAudioSubTapUIDKey] as? String)?.hasPrefix("tap-") == true)
        let uid = try #require(d[kAudioAggregateDeviceUIDKey] as? String)
        #expect(uid.hasPrefix(DeviceCatalog.domineUIDPrefix))
    }

    @Test func probeIsRunningDuringWait() async throws {
        var running = false
        permission.wait = { [hal] in running = hal.isRunning }
        _ = try await permission.capture()
        #expect(running)
    }

    @Test(arguments: [
        (FakeHAL.FailPoint.ownProcess, [FakeHAL.Op]()),
        (.createTap, []),
        (.createAggregate, [.createTap(excluding: [42]), .destroyTap]),
        (.createIOProc, [.createTap(excluding: [42]), .createAggregate, .destroyAggregate, .destroyTap]),
        (.start, [.createTap(excluding: [42]), .createAggregate, .createIOProc,
                  .destroyIOProc, .destroyAggregate, .destroyTap]),
    ])
    func failureUnwinds(point: FakeHAL.FailPoint, expected: [FakeHAL.Op]) async {
        hal.failures[point] = kAudioHardwareUnspecifiedError
        await #expect(throws: EngineError.self) { try await self.permission.capture() }
        #expect(hal.ops == expected)
        expectNothingLive()
    }

    @Test func unknownOwnProcessIsRefused() async {
        hal.ownProcess = kAudioObjectUnknown
        await #expect(throws: EngineError.noOwnProcessObject) { try await self.permission.capture() }
        #expect(hal.ops.isEmpty)
    }

    // MARK: Status

    @Test func startsUnknown() {
        #expect(permission.status == .unknown)
        #expect(!permission.isProbing)
    }

    @Test func silenceIsNotConfirmed() async {
        feed(0)
        await permission.request()
        #expect(permission.status == .notConfirmed)
        #expect(!store.audioCaptureWorking)
    }

    @Test func audioIsWorkingAndPersists() async {
        feed(0.2)
        await permission.request()
        #expect(permission.status == .working)
        #expect(store.audioCaptureWorking)
        #expect(AudioCapturePermission(hal: hal, store: store).status == .working)
    }

    @Test func laterSilenceKeepsWorking() async {
        feed(0.2)
        await permission.request()
        feed(0)
        await permission.request()
        #expect(permission.status == .working)
    }

    @Test func failedProbeIsNotConfirmed() async {
        hal.failures[.createTap] = kAudioHardwareUnspecifiedError
        await permission.request()
        #expect(permission.status == .notConfirmed)
        #expect(!permission.isProbing)
    }

    @Test func isProbingWhileCapturing() async {
        var probing = false
        permission.wait = { [weak permission] in probing = permission?.isProbing ?? false }
        await permission.request()
        #expect(probing)
        #expect(!permission.isProbing)
    }

    @Test func markWorkingPersists() {
        permission.markWorking()
        #expect(permission.status == .working)
        #expect(store.audioCaptureWorking)
    }
}
