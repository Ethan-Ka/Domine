import Foundation
import Testing
@testable import Domine

/// The menu bar panel's speaker list per mode, its tone and battery state,
/// and the menu bar item's label.
@MainActor
final class StatusMenuStateTests {
    static let gripA = EngineTests.gripA
    static let gripB = EngineTests.gripB
    static let gripC = FakeHAL.Device(uid: "60-FD-A6-19-AA-01:output", name: "JBL Grip", sampleRate: 44_100)
    static let gripD = FakeHAL.Device(uid: "60-FD-A6-19-AA-02:output", name: "JBL Grip", sampleRate: 44_100)
    static let speakers = AppModelTests.speakers

    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let model: AppModel

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        model = AppModel(hal: hal, defaults: defaults, services: FakeSystem().services)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func startWithGrips() {
        hal.add(Self.speakers)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        hal.setDefault(uid: Self.speakers.uid)
        model.start()
        model.assign(Self.gripA.uid, to: .frontLeft)
        model.assign(Self.gripB.uid, to: .frontRight)
    }

    // MARK: Speaker list per mode

    @Test func stereoListsTwoSpeakersAndOffersSwap() {
        startWithGrips()
        let state = model.statusMenuState
        #expect(state.mode == .stereo)
        #expect(state.canSwap)
        #expect(state.speakers.map(\.position) == ["Front Left", "Front Right"])
        #expect(state.speakers.map(\.uid) == [Self.gripA.uid, Self.gripB.uid])
        #expect(state.speakers.map(\.connection) == [.connected, .connected])
        #expect(state.speakers[0].deviceLabel == "JBL Grip (\(OutputDevice.suffix(forUID: Self.gripA.uid)))")
    }

    @Test func singleListsOneSpeakerAndNoSwap() {
        startWithGrips()
        model.setRoutingMode(.single)
        let state = model.statusMenuState
        #expect(state.mode == .single)
        #expect(!state.canSwap)
        #expect(state.speakers.count == 1)
        #expect(state.speakers[0].position == AppModel.singleSpeakerTitle)
        #expect(state.speakers[0].uid == Self.gripA.uid)
    }

    @Test func surroundListsEverySpeakerWithItsPosition() {
        startWithGrips()
        hal.add(Self.gripC)
        hal.add(Self.gripD)
        model.setRoutingMode(.surround)
        model.addSurroundSpeaker(uid: Self.gripC.uid)
        model.addSurroundSpeaker(uid: Self.gripD.uid)
        let state = model.statusMenuState
        #expect(state.mode == .surround)
        #expect(!state.canSwap)
        #expect(state.isSurroundAvailable)
        let placed = model.surroundSpeakers
        #expect(placed.count == 4)
        #expect(state.speakers.map(\.uid) == placed.map(\.uid))
        #expect(state.speakers.map(\.position) == placed.map { SurroundCardInfo.title(forAzimuth: Double($0.azimuth)) })

        hal.remove(uid: Self.gripD.uid)
        model.syncWithCatalog()
        let after = model.statusMenuState
        #expect(after.speakers.count == 4)
        #expect(after.speakers.first { $0.uid == Self.gripD.uid }?.connection == .notConnected)
    }

    @Test func surroundWithNoSpeakersListsNone() {
        model.start()
        model.setRoutingMode(.surround)
        #expect(model.statusMenuState.speakers.isEmpty)
    }

    @Test func modeEditReachesTheModel() {
        startWithGrips()
        var edited = model.statusMenuState
        edited.mode = .single
        model.applyStatusMenuEdit(edited)
        #expect(model.routingMode == .single)
        #expect(model.statusMenuState.speakers.count == 1)
    }

    // MARK: Battery and tone

    @Test func batteryIsLowAtFifteenPercentOrLess() {
        startWithGrips()
        model.batteryPercent = [Self.gripA.uid: 15, Self.gripB.uid: 16]
        let speakers = model.statusMenuState.speakers
        #expect(speakers[0].batteryPercent == 15)
        #expect(speakers[0].isLowBattery)
        #expect(speakers[1].batteryPercent == 16)
        #expect(!speakers[1].isLowBattery)
    }

    @Test func noBatteryIsNotLow() {
        startWithGrips()
        let speaker = model.statusMenuState.speakers[0]
        #expect(speaker.batteryPercent == nil)
        #expect(!speaker.isLowBattery)
    }

    @Test func identifyMarksThatRowPlaying() {
        startWithGrips()
        #expect(model.statusMenuState.speakers.allSatisfy { !$0.isPlayingTone })
        model.statusMenuActions.identifySpeaker(Self.gripB.uid)
        let speakers = model.statusMenuState.speakers
        #expect(!speakers[0].isPlayingTone)
        #expect(speakers[1].isPlayingTone)
        model.tones.stop()
        #expect(model.statusMenuState.speakers.allSatisfy { !$0.isPlayingTone })
    }

    @Test func identifyWhileRoutingMarksThePositionPlaying() async {
        startWithGrips()
        await model.startRouting()
        model.statusMenuActions.identifySpeaker(Self.gripA.uid)
        let speakers = model.statusMenuState.speakers
        #expect(speakers[0].isPlayingTone)
        #expect(!speakers[1].isPlayingTone)
        model.cancelTone()
    }

    @Test func connectionTitles() {
        #expect(StatusMenuConnection.connected.title == "Connected")
        #expect(StatusMenuConnection.connecting.title == "Connecting")
        #expect(StatusMenuConnection.notConnected.title == "Not connected")
        #expect(StatusMenuConnection.unassigned.title == nil)
        var card = SpeakerCardState(position: .frontLeft, sideTag: "L", statusText: "Not connected", connection: .disconnected)
        #expect(AppModel.statusMenuConnection(card) == .notConnected)
        card.isReconnecting = true
        #expect(AppModel.statusMenuConnection(card) == .connecting)
    }

    // MARK: Menu bar item

    @Test func menuBarShowsIsSavedAndDefaultsToIconOnly() {
        #expect(model.menuBarShows == .iconOnly)
        #expect(model.menuBarLabel == MenuBarLabelState(showsWarning: false, text: nil))
        model.menuBarShows = .iconAndMode
        let reopened = AppModel(hal: FakeHAL(), defaults: defaults, services: FakeSystem().services)
        #expect(reopened.menuBarShows == .iconAndMode)
    }

    @Test func menuBarTextFollowsTheSetting() {
        startWithGrips()
        model.menuBarShows = .iconAndMode
        #expect(model.menuBarLabel.text == "Stereo")
        model.menuBarShows = .iconAndVolume
        #expect(model.menuBarLabel.text == VolumeText.label(Double(model.pairSettings.masterVolume)))
        model.setMuted(true)
        #expect(model.menuBarLabel.text == "Muted")
    }

    @Test func menuBarWarnsWhileASpeakerIsMissing() async {
        startWithGrips()
        await model.startRouting()
        #expect(model.engine.state == .running)
        #expect(!model.menuBarLabel.showsWarning)
        hal.remove(uid: Self.gripB.uid)
        await model.engine.speakerCheck?.value
        #expect(model.menuBarLabel.showsWarning)
    }
}
