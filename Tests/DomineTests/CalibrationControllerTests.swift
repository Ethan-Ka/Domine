import CoreAudio
import DomineDSP
import Foundation
import Testing
@testable import Domine

/// Auto-calibration against the fake HAL: which device gets the recorder
/// IOProc, teardown order, chirp mode, and how a result reaches the delay.
@MainActor
final class CalibrationControllerTests {
    static let mic = FakeHAL.Device(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                                    outputChannels: 0, transportType: kAudioDeviceTransportTypeBuiltIn,
                                    inputStreams: [1], sampleRate: 48_000)
    static let speakers = AppModelTests.speakers
    static let gripA = EngineTests.gripA
    /// A Bluetooth headset's input. Calibration must never open it.
    static let headsetInput = FakeHAL.Device(uid: "AA-BB-CC-DD-EE-FF:input", name: "AirPods",
                                             outputChannels: 0, inputStreams: [1])
    static let gripB = EngineTests.gripB

    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let system = FakeSystem()
    let model: AppModel
    var chirpsDuringWait: [Bool] = []
    var runningDuringWait = false

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        model = AppModel(hal: hal, defaults: defaults, services: system.services)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func setUp(withMic: Bool = true, offset: Double = 12, granted: Bool = true) {
        hal.add(Self.speakers)
        hal.add(Self.headsetInput)
        if withMic { hal.add(Self.mic) }
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        model.start()
        model.calibration.requestMicAccess = { granted }
        model.calibration.waitQuiet = {}
        model.calibration.wait = { [unowned self] in
            chirpsDuringWait.append(model.engine.calibrationChirps)
            runningDuringWait = hal.isRunning
        }
        model.calibration.analyze = { _, _, _, _ in .success(offsetMs: offset, windows: 5) }
    }

    private func calibrate() async {
        model.openTuning()
        model.tuningActions.autoCalibrate?()
        #expect(model.tuningState.calibrationStatus == .listening)
        await model.calibrationTask?.value
    }

    @Test func micStartFailureShowsItsOwnLine() async {
        setUp()
        let hal = hal
        model.calibration.requestMicAccess = { hal.failures[.start] = -1; return true }
        await calibrate()
        #expect(model.tuningState.calibrationStatus == .failed("Could not start the microphone"))
    }

    @Test func recordsOnlyOnTheBuiltInMic() async {
        setUp()
        await calibrate()
        let micID = hal.id(forUID: Self.mic.uid)!
        let bluetooth = [Self.headsetInput.uid, Self.gripA.uid, Self.gripB.uid].compactMap { hal.id(forUID: $0) }
        #expect(hal.ioProcDevices.filter { $0 == micID }.count == 1)
        #expect(hal.ioProcDevices.allSatisfy { !bluetooth.contains($0) })
        #expect(hal.liveIOProcCount == 1) // only the engine's
    }

    @Test func bluetoothOnlyInputsMakeItUnavailable() {
        setUp(withMic: false)
        #expect(CalibrationController.builtInMicrophone(hal: hal) == nil)
        model.openTuning()
        #expect(model.tuningActions.autoCalibrate == nil)
    }

    @Test func bluetoothOnlyInputsFailWithReason() async {
        setUp(withMic: false)
        let outcome = await model.calibration.run(kernelRate: 44_100) { _ in }
        #expect(outcome == .failed("No built-in microphone"))
        #expect(hal.ioProcDevices.isEmpty)
    }

    @Test func tearsDownInReverseAndRestoresTheRate() async {
        setUp()
        await model.startRouting()
        let before = hal.ops.count
        await calibrate()
        let ops = Array(hal.ops.dropFirst(before))
        #expect(ops == [
            .setSampleRate(uid: Self.mic.uid), .createIOProc, .start,
            .stop, .destroyIOProc, .setSampleRate(uid: Self.mic.uid),
        ])
        #expect(hal.sampleRate(uid: Self.mic.uid) == 48_000)
    }

    @Test func chirpModeOnlyWhileRecording() async {
        setUp()
        await calibrate()
        #expect(chirpsDuringWait == [true])
        #expect(runningDuringWait)
        #expect(!model.engine.calibrationChirps)
        #expect(model.engine.state == .running)
    }

    @Test func rightLateDelaysTheLeft() async {
        setUp(offset: 12)
        await calibrate()
        #expect(model.pairSettings.delayMs == -12)
        #expect(model.tuningState.calibrationStatus == .done("Right was 12 ms late. Delay set."))
        let saved = AppModel(hal: hal, defaults: defaults, services: system.services)
        #expect(saved.pairSettings.delayMs == -12)
    }

    @Test func leftLateBeyondNormalRangeWidens() async {
        setUp(offset: -120.4)
        await calibrate()
        #expect(model.pairSettings.delayMs == 120)
        #expect(model.pairSettings.extendedRange)
        #expect(model.tuningState.calibrationStatus == .done("Left was 120 ms late. Delay set."))
    }

    @Test func analyzerFailureShowsReason() async {
        setUp()
        model.calibration.analyze = { _, _, _, _ in .failure(reason: "Too noisy") }
        await calibrate()
        guard case .failed(let reason, false) = model.tuningState.calibrationStatus else {
            Issue.record("expected a failure")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test func weakSpeakerIsNamedWithItsSuffix() async {
        setUp()
        model.calibration.analyze = { _, _, _, _ in .failure(reason: CalibrationAnalyzer.weakFalling) }
        await calibrate()
        let expected = model.tooQuietMessage(uid: model.rightUID)
        #expect(model.tuningState.calibrationStatus == .failed(expected))
        #expect(expected.hasSuffix(" was too quiet to measure. Turn it up and try again."))
        #expect(expected.contains("(\(OutputDevice.suffix(forUID: model.rightUID ?? "")))"))
    }

    @Test func noisyRoomSaysSo() async {
        setUp()
        model.calibration.analyze = { _, _, _, _ in .failure(reason: "Too noisy") }
        await calibrate()
        #expect(model.tuningState.calibrationStatus == .failed(CalibrationOutcome.tooNoisyMessage))
    }

    @Test func permissionDeniedOffersSettings() async {
        setUp(granted: false)
        await calibrate()
        #expect(model.tuningState.calibrationStatus == .failed("Microphone access is off", offersPrivacySettings: true))
        #expect(hal.ioProcDevices.allSatisfy { $0 != hal.id(forUID: Self.mic.uid) })
        #expect(chirpsDuringWait.isEmpty)
        model.tuningActions.openMicrophoneSettings()
        #expect(system.openedURLs == [CalibrationController.privacySettingsURL])
    }

    @Test func recorderCapturesTheMic() async {
        hal.add(Self.mic)
        let controller = CalibrationController(hal: hal)
        controller.requestMicAccess = { true }
        controller.waitQuiet = {}
        controller.wait = { [hal] in
            let input = FakeBufferList(channelsPerBuffer: [1], frames: 4, fill: 0.25)
            let output = FakeBufferList(channelsPerBuffer: [1], frames: 0)
            hal.render(input: input, output: output)
        }
        nonisolated(unsafe) var seen: [Float] = []
        controller.analyze = { recording, rate, rising, falling in
            seen = recording
            #expect(rate == 48_000)
            #expect(rising.count == falling.count && !rising.isEmpty)
            return .success(offsetMs: 0, windows: 5)
        }
        let outcome = await controller.run(kernelRate: 48_000) { _ in }
        #expect(outcome == .measured(offsetMs: 0))
        #expect(seen == [0.25, 0.25, 0.25, 0.25])
        #expect(hal.liveIOProcCount == 0)
        #expect(!hal.ops.contains(.setSampleRate(uid: Self.mic.uid)))
    }

    /// Chirps that straddle the analyzer's window edge still pair up after alignment.
    @Test func alignsChirpsNearTheWindowEdge() {
        let rate = 48_000.0
        let frames = Int(0.14 * rate)
        var rising = [Float](repeating: 0, count: frames)
        var falling = [Float](repeating: 0, count: frames)
        domine_calibration_chirp(&rising, UInt32(frames), rate, 1)
        domine_calibration_chirp(&falling, UInt32(frames), rate, 0)
        // Faint deterministic noise: the analyzer needs a nonzero noise floor.
        var seed: UInt32 = 1
        var recording = (0..<Int(5.5 * rate)).map { _ -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.02
        }
        let lag = 960 // right arrives 20 ms after left
        for k in 0..<5 {
            let a = k * 48_000 + 47_500
            for i in 0..<frames where a + i < recording.count { recording[a + i] += rising[i] }
            for i in 0..<frames where a + lag + i < recording.count { recording[a + lag + i] += falling[i] }
        }
        let result = CalibrationController.analyzeAligned(recording: recording, sampleRate: rate,
                                                          rising: rising, falling: falling)
        guard case .success(let offset, _, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(abs(offset - 20) < 0.1)
        #expect(CalibrationAnalyzer.delaySetting(forOffsetMs: offset) == -20)
    }
}
