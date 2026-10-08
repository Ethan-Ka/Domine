import CoreAudio
import Foundation
import Testing
@testable import Domine

/// What the main window and menu show while one speaker is missing
/// (docs/mockups/Disconnected.dc.html).
@MainActor
final class MonoFallbackUITests {
    static let gripA = EngineTests.gripA
    static let gripB = EngineTests.gripB
    static let speakers = AppModelTests.speakers
    static let dac = OutputRestoreTests.dac

    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let model: AppModel
    let system = FakeSystem()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        model = AppModel(hal: hal, defaults: defaults, services: system.services)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func route() async {
        hal.add(Self.speakers)
        hal.add(Self.dac)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        hal.setDefault(uid: Self.speakers.uid)
        model.start()
        await model.startRouting()
        #expect(model.engine.state == .running)
    }

    private func settle() async {
        await model.engine.speakerCheck?.value
    }

    @Test func rightMissingShowsMonoFallback() async {
        await route()
        hal.remove(uid: Self.gripB.uid)
        await settle()

        let state = model.mainWindowState
        #expect(state.isOn)
        #expect(state.statusLine == "Mono fallback")
        #expect(state.bannerMessage == "Front Right disconnected. Front Left plays both sides until it reconnects. A phone connected to it can take over, so check for one.")

        let left = state.speaker(at: .frontLeft)
        #expect(left.connection == .connected)
        #expect(left.sideTag == "L+R")
        #expect(left.statusText == "Mono fallback")
        #expect(left.isMonoFallback)
        #expect(left.uidSuffix == "4F2A")

        let right = state.speaker(at: .frontRight)
        #expect(right.connection == .disconnected)
        #expect(right.sideTag == "R")
        #expect(right.statusText == "Not connected")
        #expect(right.deviceName == "JBL Grip")
        #expect(right.uidSuffix == "9C11")
        #expect(!right.isMonoFallback)
    }

    @Test func leftMissingNamesTheRealSide() async {
        await route()
        hal.remove(uid: Self.gripA.uid)
        await settle()

        let state = model.mainWindowState
        #expect(state.bannerMessage == "Front Left disconnected. Front Right plays both sides until it reconnects. A phone connected to it can take over, so check for one.")
        #expect(state.speaker(at: .frontLeft).statusText == "Not connected")
        #expect(state.speaker(at: .frontRight).sideTag == "L+R")
        #expect(state.speaker(at: .frontRight).statusText == "Mono fallback")
    }

    @Test func listedButNotAliveReadsNotConnected() async {
        await route()
        hal.setAlive(uid: Self.gripB.uid, false)
        await settle()
        let right = model.mainWindowState.speaker(at: .frontRight)
        #expect(right.connection == .disconnected)
        #expect(right.statusText == "Not connected")
        #expect(model.statusMenuState.right.isConnected == false)
        #expect(model.statusMenuState.statusText == "Mono fallback")
    }

    @Test func monoFallbackBannerWinsOverThePairingHint() async {
        await route()
        hal.remove(uid: Self.gripB.uid)
        await settle()
        #expect(model.mainWindowState.bannerMessage?.hasPrefix("Front Right disconnected.") == true)
    }

    @Test func returnGoesBackToStereo() async {
        await route()
        hal.remove(uid: Self.gripB.uid)
        await settle()
        hal.add(Self.gripB)
        await settle()

        let state = model.mainWindowState
        #expect(model.engine.state == .running)
        #expect(state.statusLine == "Playing")
        #expect(state.bannerMessage == nil)
        #expect(state.speaker(at: .frontLeft).sideTag == "L")
        #expect(state.speaker(at: .frontLeft).statusText == "Connected")
        #expect(state.speaker(at: .frontRight).sideTag == "R")
        #expect(state.speaker(at: .frontRight).connection == .connected)
    }

    @Test func testTonesStayOnTheEngineInMonoFallback() async {
        await route()
        hal.remove(uid: Self.gripB.uid)
        await settle()
        #expect(model.mainWindowState.canPlayTestTones)
        model.playTestTone(.left)
        #expect(model.engine.testTone == .left)
        #expect(model.tones.playingUID == nil)
        model.cancelTone()
    }

    @Test func bothGoneStopsAndRestoresThePreviousOutput() async {
        await route()
        #expect(model.store.outputNeedsRestore)
        hal.setDefault(uid: Self.dac.uid)
        hal.remove(uid: Self.gripB.uid)
        await settle()
        hal.remove(uid: Self.gripA.uid)
        await settle()

        #expect(model.engine.state == .idle)
        #expect(!model.mainWindowState.isOn)
        #expect(model.mainWindowState.statusLine == "Both speakers disconnected")
        #expect(model.mainWindowState.bannerMessage == nil)
        #expect(hal.defaultOutputUID == Self.speakers.uid)
        #expect(!model.store.outputNeedsRestore)
    }
}
