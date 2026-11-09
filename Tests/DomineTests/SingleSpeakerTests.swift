import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Single mode: everything on one speaker, (L + R) / 2 on both channels.
@MainActor
final class SingleSpeakerTests {
    static let gripA = EngineTests.gripA
    static let gripB = EngineTests.gripB
    static let speakers = FakeHAL.Device(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                                         transportType: kAudioDeviceTransportTypeBuiltIn)

    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let system = FakeSystem()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func render(_ engine: Engine, frames: Int = 512) -> FakeBufferList {
        let input = FakeBufferList(channelsPerBuffer: [2], frames: frames)
        input.set(buffer: 0, channel: 0, Array(repeating: 0.5, count: frames))
        input.set(buffer: 0, channel: 1, Array(repeating: 0.25, count: frames))
        let out = FakeBufferList(channelsPerBuffer: [2], frames: frames, fill: 9)
        hal.render(input: input, output: out)
        return out
    }

    private var subDeviceUIDs: [String] {
        (hal.lastAggregateDescription?[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? [])
            .compactMap { $0[kAudioSubDeviceUIDKey] as? String }
    }

    // MARK: Engine

    @Test func runsOnOneSpeakerWithTheMonoSum() async {
        hal.add(Self.gripA)
        let engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero)
        await engine.start(single: Self.gripA.uid)

        #expect(engine.state == .running)
        #expect(engine.isSingleSpeaker)
        #expect(subDeviceUIDs == [Self.gripA.uid])
        #expect(engine.layout == AggregateLayout(inFirstBuffer: 0, tapBuffers: 1, outAChannelOffset: 0, outBChannelOffset: nil))
        let out = render(engine)
        #expect(out.channel(0) == Array(repeating: 0.375, count: 512))
        #expect(out.channel(1) == Array(repeating: 0.375, count: 512))
    }

    @Test func gainScalesTheOneSpeaker() async {
        hal.add(Self.gripA)
        let engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero)
        engine.leftGain = 0.5
        await engine.start(single: Self.gripA.uid)
        let out = render(engine)
        #expect(out.channel(0) == Array(repeating: 0.1875, count: 512))
        #expect(out.channel(1) == Array(repeating: 0.1875, count: 512))
    }

    @Test func refusesWithoutASpeaker() async {
        let engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero)
        await engine.start(single: nil)
        #expect(engine.state == .idle)
        #expect(engine.idleReason == .noSingleSpeaker)
        await engine.start(single: Self.gripA.uid)
        #expect(engine.idleReason == .singleMissing)
    }

    @Test func speakerLeavingStops() async {
        hal.add(Self.gripA)
        let engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero, fadeWait: { _ in })
        await engine.start(single: Self.gripA.uid)
        hal.remove(uid: Self.gripA.uid)
        await engine.speakerCheck?.value
        #expect(engine.state == .idle)
        #expect(engine.idleReason == .speakerDisconnected)
        #expect(!engine.isSingleSpeaker)
    }

    @Test func pairStartClearsSingle() async {
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        let engine = Engine(hal: hal, layoutAttempts: 3, layoutRetryDelay: .zero)
        await engine.start(single: Self.gripA.uid)
        engine.stop()
        await engine.start(left: Self.gripA.uid, right: Self.gripB.uid)
        #expect(engine.state == .running)
        #expect(!engine.isSingleSpeaker)
    }

    // MARK: Model

    @Test func modelRoutesOnlyTheLeftSpeaker() async {
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        let model = AppModel(hal: hal, defaults: defaults, services: system.services)
        model.start()
        model.setRoutingMode(.single)
        await model.startRouting()

        #expect(model.engine.state == .running)
        #expect(model.engine.isSingleSpeaker)
        #expect(subDeviceUIDs == [Self.gripA.uid])
        #expect(model.assignedSpeakerUIDs == [Self.gripA.uid])
        let state = model.mainWindowState
        #expect(state.speakers.count == 1)
        #expect(state.speakers.first?.title == "Speaker")
        #expect(state.speakers.first?.sideTag == "L+R")
        #expect(!state.canSwap)
        #expect(model.stereoSpeakerVolumeRows.map(\.title) == ["Speaker"])
    }

    @Test func singleIgnoresBalanceAndDelay() {
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        let model = AppModel(hal: hal, defaults: defaults, services: system.services)
        model.start()
        model.setRoutingMode(.single)
        let gain = model.engine.leftGain
        model.updatePairSettings { $0.balance = 0.5; $0.delayMs = 40 }
        #expect(model.engine.delayMs == 0)
        #expect(model.engine.leftGain == gain)
    }

    @Test func storedModeRoundTrips() {
        #expect(RoutingMode(rawValue: "single") == .single)
        #expect(RoutingMode.allCases.first == .single)
    }
}

/// Master volume above 100%: hardware stays at full, the kernel boosts.
@MainActor
struct VolumeBoostModelTests {
    @Test func boostGainMapsTheTopOfTheSlider() {
        #expect(PairSettings.boostGain(forMaster: 0.7) == 1)
        #expect(PairSettings.boostGain(forMaster: 1) == 1)
        #expect(abs(PairSettings.boostGain(forMaster: 2) - 3.1622777) < 1e-5)
        #expect(abs(PairSettings.boostGain(forMaster: 1.6) - 1.9952623) < 1e-5)
        #expect(PairSettings.boostGain(forMaster: 5) == PairSettings.boostGain(forMaster: 2))
    }

    @Test func labelShowsDecibelsAbove100() {
        #expect(VolumeText.label(0.5) == "50%")
        #expect(VolumeText.label(1) == "100%")
        #expect(VolumeText.label(1.4) == "+4 dB")
        #expect(VolumeText.label(2) == "+10 dB")
    }

    @Test func volumeKeysGoPast100WhenAllowed() {
        let up = VolumeKeyEvent(key: .volumeUp, isKeyDown: true, isRepeat: false, step: VolumeKeyEvent.normalStep)
        #expect(up.apply(to: 1, muted: false).0 == 1)
        #expect(up.apply(to: 1, muted: false, maximum: 2).0 == 1 + VolumeKeyEvent.normalStep)
    }
}

extension SingleSpeakerTests {
    @Test func masterAbove100BoostsAndSurroundCapsIt() {
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        let model = AppModel(hal: hal, defaults: defaults, services: system.services)
        model.start()
        model.setRoutingMode(.single)
        model.setMasterVolume(1.5)
        #expect(model.pairSettings.masterVolume == 1.5)
        #expect(abs(model.engine.boost - PairSettings.boostGain(forMaster: 1.5)) < 1e-6)
        #expect(model.mainWindowState.maxVolume == 2)
        model.setRoutingMode(.surround)
        #expect(model.pairSettings.masterVolume <= 1)
        #expect(model.engine.boost == 1)
        #expect(model.mainWindowState.maxVolume == 1)
    }
}
