import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Surround settings, migration, and the AppModel surround API (SPEC 13, 14).
@MainActor
final class SurroundModelTests {
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let hal = FakeHAL()
    let system = FakeSystem()
    var model: AppModel!

    nonisolated static func device(_ n: Int, transport: UInt32 = kAudioDeviceTransportTypeBluetooth,
                                   channels: Int = 2) -> FakeHAL.Device {
        FakeHAL.Device(uid: String(format: "60-FD-A6-19-11-%02X:output", n), name: "JBL Grip",
                       outputChannels: channels, transportType: transport, sampleRate: 44_100)
    }

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit { UserDefaults().removePersistentDomain(forName: suiteName) }

    /// Adds the devices, then makes and starts the model.
    @discardableResult
    private func start(_ devices: [FakeHAL.Device]) -> AppModel {
        for device in devices { hal.add(device) }
        // No auto-start: the tests start routing themselves.
        SettingsStore(defaults: defaults).startWhenBothConnect = false
        let model = AppModel(hal: hal, defaults: defaults, services: system.services)
        model.start()
        self.model = model
        return model
    }

    private func uids(_ devices: [FakeHAL.Device]) -> [String] { devices.map(\.uid) }

    // MARK: Settings record

    @Test func storageKeyIsSortedUIDs() {
        #expect(SurroundSettings.storageKey(uids: ["C", "A", "B"]) == "Domine.surround.A|B|C")
    }

    @Test func roundTripsThroughJSON() throws {
        var s = SurroundSettings(uids: ["A", "B", "C"])
        s.width = 45
        s.surroundLevel = 0.3
        s.orbitRate = -20
        s.rotation = 90
        s.trims = ["B": 0.5]
        s.offsetsMs = ["C": 12]
        var fx = PairSettings.SideEffects()
        fx.bassEnabled = true
        s.effects = ["A": fx]
        s.linkEffects = false
        let back = try JSONDecoder().decode(SurroundSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.speakers.map(\.azimuth) == [-30, 30, -110])
    }

    @Test func decodingIsTolerant() throws {
        let json = #"""
        {"speakers":[{"uid":"A","azimuth":200},{"azimuth":5},{"uid":"B","azimuth":"x","distance":40},{"uid":"A","azimuth":0}],
         "width":500,"surroundLevel":"loud","orbitRate":9999,"linkEffects":false,"spatialRoomMs":1}
        """#
        let s = try JSONDecoder().decode(SurroundSettings.self, from: Data(json.utf8))
        #expect(s.uids == ["A", "B"])
        #expect(s.speakers[0].azimuth == -160)
        #expect(s.speakers[0].distance == 2)
        #expect(s.speakers[1].azimuth == 0)
        #expect(s.speakers[1].distance == 10)
        #expect(s.width == 90)
        #expect(s.surroundLevel == 0.7)
        #expect(s.orbitRate == 720)
        #expect(s.spatialRoomMs == 5)
        #expect(!s.linkEffects)
        let empty = try JSONDecoder().decode(SurroundSettings.self, from: Data("{}".utf8))
        #expect(empty == SurroundSettings())
    }

    @Test func carryingKeepsStayingSpeakers() {
        var s = SurroundSettings(uids: ["A", "B", "C"])
        s.speakers[2].azimuth = 77
        s.trims = ["B": 0.5, "C": 0.2]
        let next = s.carried(to: ["A", "C", "D"])
        #expect(next.uids == ["A", "C", "D"])
        #expect(next.speakers[1].azimuth == 77)
        #expect(next.speakers[2].azimuth == SurroundSpeaker.defaultAzimuth(forIndex: 2))
        #expect(next.speakers[2].distance == 2)
        #expect(next.trims == ["C": 0.2])
    }

    // MARK: Migration (SPEC 13.7)

    @Test func quadSetMigratesOnceAtLaunch() throws {
        let store = SettingsStore(defaults: defaults)
        store.lastLeftUID = "FL"
        store.lastRightUID = "FR"
        store.lastRearLeftUID = "RL"
        store.lastRearRightUID = "RR"
        defaults.set("quad", forKey: "Domine.routingMode")
        store.setPairSettings(PairSettings(delayMs: 12, balance: 0.25), leftUID: "FL", rightUID: "FR")
        var quad = QuadSettings()
        quad.rearTrim = 0.5
        quad.rearMode = 0
        quad.linkRears = false
        quad.rearLeft.bassEnabled = true
        store.setQuadSettings(quad, uids: ["FL", "FR", "RL", "RR"])

        let model = AppModel(hal: FakeHAL(), defaults: defaults, services: system.services)
        #expect(model.routingMode == .surround)
        let s = model.surroundSettings
        #expect(s.uids == ["FL", "FR", "RL", "RR"])
        #expect(s.speakers.map(\.azimuth) == [-30, 30, -110, 110])
        #expect(s.speakers.allSatisfy { $0.distance == 2 })
        #expect(s.offsetsMs == ["FR": 12])
        #expect(s.trim(for: "FL") == 0.75)
        #expect(s.trim(for: "FR") == 1)
        #expect(s.surroundLevel == 0.5)
        #expect(s.spatialAmount == 0)
        #expect(!s.linkEffects)
        // Unlinked rears with linked pair effects: both rears take the rear left's.
        #expect(s.resolvedEffects(for: "RL").bassEnabled)
        #expect(s.resolvedEffects(for: "RR").bassEnabled)
        #expect(!s.resolvedEffects(for: "FL").bassEnabled)
        #expect(store.lastSurroundUIDs == ["FL", "FR", "RL", "RR"])
        // Old keys stay for a downgrade.
        #expect(defaults.data(forKey: QuadSettings.storageKey(uids: ["FL", "FR", "RL", "RR"])) != nil)

        // Idempotent: a later launch keeps the user's surround edits.
        model.setSurroundWidth(60)
        let again = AppModel(hal: FakeHAL(), defaults: defaults, services: system.services)
        #expect(again.surroundSettings.width == 60)
    }

    @Test func matrixBecomesDefaultAmountAndSpatialCarries() {
        var matrix = QuadSettings()
        matrix.rearMode = 1
        let m = SurroundSettings.migrated(frontLeft: "A", frontRight: "B", rearLeft: "C", rearRight: "D",
                                          pair: PairSettings(), quad: matrix)
        #expect(m.spatialAmount == 0.6)
        #expect(m.linkEffects)
        var spatial = QuadSettings()
        spatial.rearMode = 3
        spatial.spatialAmount = 0.2
        spatial.spatialRoomMs = 22
        let p = SurroundSettings.migrated(frontLeft: "A", frontRight: "B", rearLeft: "C", rearRight: "D",
                                          pair: PairSettings(delayMs: -8), quad: spatial)
        #expect(p.spatialAmount == 0.2)
        #expect(p.spatialRoomMs == 22)
        #expect(p.offsetsMs == ["A": 8])
    }

    // MARK: The set

    @Test func firstSwitchSeedsFromThePairOnly() {
        let devices = (1...3).map { Self.device($0) }
        start(devices + [Self.builtIn])
        model.assign(devices[0].uid, to: .frontLeft)
        model.assign(devices[1].uid, to: .frontRight)
        #expect(model.isSurroundAvailable)
        model.setRoutingMode(.surround)
        let pair = [devices[0].uid, devices[1].uid]
        #expect(model.surroundSpeakers.map(\.uid) == pair)
        #expect(model.surroundSpeakers.map(\.azimuth) == [-30, 30])
        #expect(model.store.lastSurroundUIDs == pair)
    }

    @Test func firstSwitchAppliesSwap() {
        let devices = (1...3).map { Self.device($0) }
        start(devices)
        model.assign(devices[0].uid, to: .frontLeft)
        model.assign(devices[1].uid, to: .frontRight)
        model.engine.swapSides = true
        model.setRoutingMode(.surround)
        #expect(model.surroundSpeakers.map(\.uid) == [devices[1].uid, devices[0].uid])
    }

    @Test func surroundNeedsTwoTwoChannelOutputs() {
        start([Self.device(1), Self.device(2, channels: 1)])
        #expect(!model.isSurroundAvailable)
        model.addSurroundSpeaker(uid: Self.device(2).uid)
        #expect(model.surroundSpeakers.isEmpty)
    }

    @Test func monoIsOffByDefaultSavedAndPushed() throws {
        let devices = (1...2).map { Self.device($0) }
        start(devices)
        model.assign(devices[0].uid, to: .frontLeft)
        model.assign(devices[1].uid, to: .frontRight)
        model.setRoutingMode(.surround)
        #expect(!model.surroundSettings.mono)
        #expect(!model.engine.surroundMono)
        model.setSurroundMono(true)
        #expect(model.engine.surroundMono)
        #expect(model.soundSheetState.surround?.isMono == true)
        let saved = try #require(model.store.surroundSettings(uids: uids(devices)))
        #expect(saved.mono)
        let old = try JSONDecoder().decode(SurroundSettings.self, from: Data(#"{"speakers":[{"uid":"A","azimuth":0}]}"#.utf8))
        #expect(!old.mono)
    }

    @Test func orbitResetCountsForTheStage() {
        start([])
        let before = model.mainWindowState.surround.orbitResetCount
        model.resetSurroundOrbit()
        #expect(model.mainWindowState.surround.orbitResetCount == before + 1)
    }

    @Test func twoSpeakersAreEnoughForSurround() {
        let devices = (1...2).map { Self.device($0) }
        start(devices)
        model.assign(devices[0].uid, to: .frontLeft)
        model.assign(devices[1].uid, to: .frontRight)
        #expect(model.isSurroundAvailable)
        model.setRoutingMode(.surround)
        #expect(model.surroundSpeakers.map(\.uid) == uids(devices))
        #expect(model.surroundSpeakers.map(\.azimuth) == [-30, 30])
    }

    @Test func addAndRemoveKeepOrderSkipDuplicatesAndCap() {
        start([])
        for n in 1...20 { model.addSurroundSpeaker(uid: "S\(n)") }
        #expect(model.surroundSpeakers.count == SurroundSpeaker.maxCount)
        model.addSurroundSpeaker(uid: "S1")
        #expect(model.surroundSpeakers.count == SurroundSpeaker.maxCount)
        #expect(model.surroundSpeakers.map(\.azimuth) == (0..<16).map { SurroundSpeaker.defaultAzimuth(forIndex: $0) })
        model.removeSurroundSpeaker(uid: "S2")
        #expect(model.surroundSpeakers.count == 15)
        #expect(model.surroundSpeakers[1].uid == "S3")
        #expect(model.surroundSpeakers[1].azimuth == SurroundSpeaker.defaultAzimuth(forIndex: 2))
        let again = AppModel(hal: FakeHAL(), defaults: defaults, services: system.services)
        #expect(again.surroundSpeakers == model.surroundSpeakers)
    }

    @Test func moveWrapsClampsAndReachesTheEngine() {
        start([])
        for uid in ["A", "B", "C"] { model.addSurroundSpeaker(uid: uid) }
        model.moveSurroundSpeaker(uid: "B", azimuth: 200, distance: 20)
        #expect(model.surroundSpeakers[1].azimuth == -160)
        #expect(model.surroundSpeakers[1].distance == 10)
        model.moveSurroundSpeaker(uid: "C", azimuth: -540, distance: 0.1)
        #expect(model.surroundSpeakers[2].azimuth == 180)
        #expect(model.surroundSpeakers[2].distance == 0.5)
        model.moveSurroundSpeaker(uid: "A", azimuth: .nan, distance: .infinity)
        #expect(model.surroundSpeakers[0].azimuth == 0)
        #expect(model.surroundSpeakers[0].distance == 2)
        #expect(model.engine.surroundSpeakers == model.surroundSpeakers)
        model.moveSurroundSpeaker(uid: "missing", azimuth: 10, distance: 1)
        #expect(model.surroundSpeakers.count == 3)
    }

    @Test func presetsKeepClockwiseOrder() {
        start([])
        for uid in ["A", "B", "C", "D"] { model.addSurroundSpeaker(uid: uid) }
        model.applySurroundPreset(.ring)
        #expect(model.surroundSpeakers.map(\.azimuth) == [-45, 45, -135, 135])
        model.applySurroundPreset(.quad)
        #expect(model.surroundSpeakers.map(\.azimuth) == [-30, 30, -110, 110])
        model.applySurroundPreset(.five)
        #expect(model.surroundSpeakers.map(\.azimuth) == [-30, 30, -110, 110])
        #expect(SurroundPreset.five.azimuths(count: 5) == [-30, 0, 30, -110, 110])
        #expect(SurroundPreset.seven.isEnabled(speakerCount: 7))
        #expect(!SurroundPreset.seven.isEnabled(speakerCount: 6))
        #expect(SurroundPreset.ring.azimuths(count: 3) == [-120, 0, 120])
        #expect(SurroundPreset.allCases.map(\.title) == ["Quad", "5 speaker", "7 speaker", "Ring"])
    }

    @Test func fieldControlsClampPersistAndReachTheEngine() {
        start([])
        for uid in ["A", "B", "C"] { model.addSurroundSpeaker(uid: uid) }
        model.setSurroundWidth(200)
        model.setSurroundLevel(-1)
        model.setOrbitRate(1000)
        model.setSurroundRotation(270)
        model.setSpatial(amount: 0.3, roomMs: 22)
        #expect(model.engine.surroundWidth == 90)
        #expect(model.engine.surroundLevel == 0)
        #expect(model.engine.orbitRate == 720)
        #expect(model.engine.rotation == -90)
        #expect(model.engine.spatialAmount == 0.3)
        let again = AppModel(hal: FakeHAL(), defaults: defaults, services: system.services)
        #expect(again.surroundSettings.width == 90)
        #expect(again.surroundSettings.rotation == -90)
        #expect(again.surroundSettings.spatialRoomMs == 22)
    }

    @Test func perSpeakerTrimOffsetAndLinkedEffects() {
        start([])
        for uid in ["A", "B", "C"] { model.addSurroundSpeaker(uid: uid) }
        model.setSurroundTrim(uid: "B", 0.5)
        model.setSurroundOffset(uid: "C", ms: 40)
        #expect(model.engine.surroundDelaysMs == ["C": 40])
        var fx = PairSettings.SideEffects()
        fx.bassEnabled = true
        model.setSurroundEffects(uid: "C", fx)
        // Linked: the edit goes to the shared (first speaker's) effects.
        #expect(model.engine.surroundEffects["B"]?.bassEnabled == true)
        model.setSurroundEffectsLinked(false)
        model.setSurroundEffects(uid: "C", PairSettings.SideEffects())
        #expect(model.engine.surroundEffects["C"]?.bassEnabled == false)
        #expect(model.engine.surroundEffects["A"]?.bassEnabled == true)
    }

    @Test func bluetoothWarningAboveFourBluetoothSpeakers() {
        let bluetooth = (1...5).map { Self.device($0) }
        let usb = Self.device(9, transport: kAudioDeviceTransportTypeUSB)
        start(bluetooth + [usb])
        for device in bluetooth.prefix(4) + [usb] { model.addSurroundSpeaker(uid: device.uid) }
        #expect(!model.showsBluetoothBandwidthWarning)
        model.addSurroundSpeaker(uid: bluetooth[4].uid)
        #expect(model.showsBluetoothBandwidthWarning)
    }

    // MARK: Routing, test tone, demo

    /// Another output outside the set, so routing has somewhere to move the default output.
    static let builtIn = device(0x30, transport: kAudioDeviceTransportTypeBuiltIn)

    @Test func routesTheSetAndPlaysPerSpeakerTones() async {
        let devices = (1...4).map { Self.device($0) }
        start(devices + [Self.builtIn])
        model.assign(devices[0].uid, to: .frontLeft)
        model.assign(devices[1].uid, to: .frontRight)
        model.setRoutingMode(.surround)
        model.changeSurroundSet(uids(devices))
        await model.startRouting()
        #expect(model.engine.state == .running)
        #expect(model.engine.surroundRoute == uids(devices))
        #expect(model.surroundLevel(uid: devices[0].uid) == 0)
        model.playTestTone(surroundUID: devices[2].uid)
        #expect(model.engine.surroundTestTone == devices[2].uid)
        #expect(model.surroundTestToneUID == devices[2].uid)
        model.cancelTone()
        #expect(model.engine.surroundTestTone == nil)

        #expect(model.canPlayDemo)
        await model.engine.setDemo(true)
        model.syncDemoStatus()
        #expect(model.demoPlaying)
        model.stopRouting()
        #expect(!model.demoPlaying)
        #expect(model.demoSectionTitle == nil)
    }

    @Test func twoConnectedRouteSurround() async {
        let devices = (1...2).map { Self.device($0) }
        start(devices + [Self.builtIn])
        model.assign(devices[0].uid, to: .frontLeft)
        model.assign(devices[1].uid, to: .frontRight)
        model.setRoutingMode(.surround)
        #expect(model.surroundRouteSpeakers?.map(\.uid) == uids(devices))
        await model.startRouting()
        #expect(model.engine.state == .running)
        #expect(model.engine.surroundRoute == uids(devices))
    }

    @Test func testSpeakersChimesEachSpeakerInTurn() async {
        let devices = (1...3).map { Self.device($0) }
        start(devices + [Self.builtIn])
        model.assign(devices[0].uid, to: .frontLeft)
        model.assign(devices[1].uid, to: .frontRight)
        model.setRoutingMode(.surround)
        model.changeSurroundSet(uids(devices))
        await model.startRouting()
        #expect(model.mainWindowState.canPlayTestTones)
        model.testSurroundSpeakers()
        for _ in 0..<100 where model.engine.surroundTestTone == nil { await Task.yield() }
        #expect(model.engine.surroundTestTone == devices[0].uid)
        #expect(model.surroundTestToneUID == devices[0].uid)
        model.cancelTone()
        #expect(model.engine.surroundTestTone == nil)
    }

    @Test func fewerThanTwoConnectedRoutesStereo() async {
        let devices = (1...3).map { Self.device($0) }
        start(devices + [Self.builtIn])
        model.assign(devices[0].uid, to: .frontLeft)
        model.assign(devices[1].uid, to: .frontRight)
        model.setRoutingMode(.surround)
        model.changeSurroundSet([devices[0].uid, devices[2].uid])
        hal.remove(uid: devices[2].uid)
        model.syncWithCatalog()
        #expect(model.surroundRouteSpeakers == nil)
        await model.startRouting()
        #expect(model.engine.surroundRoute == nil)
        #expect(model.engine.state == .running)
    }

    @Test func demoNeedsRoutingAndSectionsHaveTitles() {
        start([])
        model.startDemo()
        #expect(!model.demoPlaying)
        #expect((0...8).map { AppModel.demoSectionTitle($0) }
            == [nil, "Calibration", "Left and right", "Orbit", "Swell", "Impact", nil, "Sweep", "Silence"])
    }
}
