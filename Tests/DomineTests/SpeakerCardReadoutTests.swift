import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Sync readout, connection health, and the mono fallback tag on the stage
/// cards (docs/IDEAS.md, visual 1, 2, 9).
@MainActor
final class SpeakerCardReadoutTests {
    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let model: AppModel
    let system = FakeSystem()
    var idA: AudioObjectID = 0

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        model = AppModel(hal: hal, defaults: defaults, services: system.services)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func route() async {
        hal.add(AppModelTests.speakers)
        hal.add(OutputRestoreTests.dac)
        idA = hal.add(EngineTests.gripA)
        hal.add(EngineTests.gripB)
        hal.setDefault(uid: AppModelTests.speakers.uid)
        model.start()
        await model.startRouting()
        #expect(model.engine.state == .running)
    }

    // MARK: - Pure

    @Test func stereoSyncFollowsTheDelaySign() {
        #expect(SpeakerSync.stereo(delayMs: 42) == (a: .reference, b: .delayed(ms: 42)))
        #expect(SpeakerSync.stereo(delayMs: -7) == (a: .delayed(ms: 7), b: .reference))
        #expect(SpeakerSync.stereo(delayMs: 0.4) == (a: nil, b: nil))
    }

    @Test func surroundSyncMarksZeroAsReference() {
        let sync = SpeakerSync.surround(delaysMs: ["a": 0, "b": 4.2, "c": 12.6])
        #expect(sync == ["a": .reference, "b": .delayed(ms: 4), "c": .delayed(ms: 13)])
        #expect(SpeakerSync.surround(delaysMs: ["a": 0, "b": 0.2]).isEmpty)
    }

    @Test func syncTexts() {
        #expect(SpeakerSync.reference.text == "Timing reference")
        #expect(SpeakerSync.reference.connectorLabel == nil)
        #expect(SpeakerSync.delayed(ms: 42).text == "Delayed 42 ms")
        #expect(SpeakerSync.delayed(ms: 4).connectorLabel == "+4 ms")
    }

    @Test func healthCountsOverloadsAndDisconnects() {
        #expect(SpeakerHealth(DropoutCounts.Entry()) == .ok)
        #expect(SpeakerHealth.ok.text == nil)
        #expect(SpeakerHealth(DropoutCounts.Entry(overloads: 2, disconnects: 1)) == .dropouts(3))
        #expect(SpeakerHealth.dropouts(3).text == "Dropped out 3 times")
        #expect(SpeakerHealth.dropouts(1).text == "Dropped out once")
    }

    // MARK: - Builders

    @Test func stereoCardsShowTheDelayedSpeaker() async {
        await route()
        model.setDelayMs(42)
        let state = model.mainWindowState
        #expect(state.speaker(at: .frontLeft).sync == .reference)
        #expect(state.speaker(at: .frontRight).sync == .delayed(ms: 42))

        model.setDelayMs(-15)
        #expect(model.mainWindowState.speaker(at: .frontLeft).sync == .delayed(ms: 15))
        #expect(model.mainWindowState.speaker(at: .frontRight).sync == .reference)

        model.setDelayMs(0)
        #expect(model.mainWindowState.speaker(at: .frontLeft).sync == nil)
        #expect(model.mainWindowState.speaker(at: .frontRight).sync == nil)
    }

    @Test func monoFallbackHidesSyncAndKeepsATagThatIsNotAFault() async {
        await route()
        model.setDelayMs(42)
        hal.remove(uid: EngineTests.gripB.uid)
        await model.engine.speakerCheck?.value
        let left = model.mainWindowState.speaker(at: .frontLeft)
        #expect(left.isMonoFallback)
        #expect(left.connection == .connected)
        #expect(left.sync == nil)
        #expect(model.mainWindowState.speaker(at: .frontRight).sync == nil)
    }

    @Test func singleModeShowsNoSync() {
        model.setRoutingMode(.single)
        model.setDelayMs(42)
        #expect(model.card(for: .frontLeft).sync == nil)
    }

    @Test func overloadsShowOnTheCardUntilReset() async {
        await route()
        #expect(model.mainWindowState.speaker(at: .frontLeft).health == .ok)
        hal.fire(.processorOverload(idA))
        hal.fire(.processorOverload(idA))
        hal.fire(.processorOverload(idA))
        let left = model.mainWindowState.speaker(at: .frontLeft)
        #expect(left.health == .dropouts(3))
        #expect(left.health.text == "Dropped out 3 times")
        #expect(model.mainWindowState.speaker(at: .frontRight).health == .ok)

        model.engine.diagnostics?.resetDropoutCounts()
        #expect(model.mainWindowState.speaker(at: .frontLeft).health == .ok)
    }

    @Test func healthIsOkWhenNotRouting() {
        #expect(model.dropoutCounts.entries.isEmpty)
    }
}
