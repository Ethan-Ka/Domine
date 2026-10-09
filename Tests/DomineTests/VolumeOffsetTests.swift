import CoreAudio
import Foundation
import Testing
@testable import Domine

/// Per-speaker hardware volume offsets (SPEC 4a).
@MainActor
final class VolumeOffsetTests {
    static let gripA = EngineTests.gripA
    static let gripB = EngineTests.gripB

    let hal = FakeHAL()
    var clock = ContinuousClock.now

    static func device(_ base: FakeHAL.Device, volume: Float, decibels: ClosedRange<Float>? = nil) -> FakeHAL.Device {
        var device = base
        device.volumes = [1: volume, 2: volume]
        device.decibelRange = decibels
        return device
    }

    /// A link over A and B; B carries `offset`.
    private func makeLink(a: Float = 0.5, b: Float = 0.5, offset: Float,
                      decibels: ClosedRange<Float>? = nil) -> SpeakerVolumeLink {
        let link = SpeakerVolumeLink(hal: hal, now: { [unowned self] in self.clock })
        let idA = hal.add(Self.device(Self.gripA, volume: a, decibels: decibels))
        let idB = hal.add(Self.device(Self.gripB, volume: b, decibels: decibels))
        link.setOffsets([Self.gripB.uid: offset])
        link.attach([(Self.gripA.uid, idA), (Self.gripB.uid, idB)])
        return link
    }

    private func volume(_ uid: String) -> Float { hal.volumes(uid: uid)[1] ?? -1 }

    private func close(_ a: Float?, _ b: Float) -> Bool { a.map { abs($0 - b) < 0.0001 } ?? false }

    // MARK: Master changes

    @Test func masterChangeAppliesTheOffsetOnTheApproximateCurve() {
        let link = makeLink(offset: 6)
        link.set(0.6)
        #expect(close(volume(Self.gripA.uid), 0.6))
        #expect(close(volume(Self.gripB.uid), 0.6 + 6 / SpeakerVolumeLink.approximateSpanDb))
        #expect(link.volume == 0.6)
    }

    @Test func masterChangeUsesTheDevicesDecibelCurve() {
        let link = makeLink(offset: 6, decibels: -60...0)
        link.set(0.5)
        #expect(close(volume(Self.gripA.uid), 0.5))
        // -30 dB + 6 dB = -24 dB, which is 0.6 on a linear -60...0 curve.
        #expect(close(volume(Self.gripB.uid), 0.6))
    }

    @Test func negativeOffsetCutsTheHardware() {
        let link = makeLink(offset: -6, decibels: -60...0)
        link.set(0.5)
        #expect(close(volume(Self.gripB.uid), 0.4))
    }

    // MARK: External changes

    @Test func externalChangeMapsBackToTheMaster() {
        let link = makeLink(offset: 6)
        var reported: [Float] = []
        link.onExternalChange = { reported.append($0) }
        link.set(0.5)
        clock = clock.advanced(by: SpeakerVolumeLink.suppression)
        hal.pressVolume(uid: Self.gripB.uid, to: 0.8)
        let master: Float = 0.8 - 6 / SpeakerVolumeLink.approximateSpanDb
        #expect(close(reported.first, master))
        #expect(close(volume(Self.gripA.uid), master))
        #expect(close(volume(Self.gripB.uid), 0.8))
    }

    // MARK: Attach

    @Test func attachComparesMasterEquivalentLevels() {
        // B reads higher but sits 6 dB up, so its master level is the lower one.
        let link = makeLink(a: 0.5, b: 0.6, offset: 6)
        let master: Float = 0.6 - 6 / SpeakerVolumeLink.approximateSpanDb
        #expect(close(link.volume, master))
        #expect(close(volume(Self.gripA.uid), master))
        #expect(close(volume(Self.gripB.uid), 0.6))
    }

    @Test func attachWithMatchingOffsetLevelsWritesNothing() {
        _ = makeLink(a: 0.5, b: 0.6, offset: 6, decibels: -60...0)
        #expect(hal.volumeWrites.isEmpty)
    }

    // MARK: Maximum

    @Test func offsetPastFullScaleClampsAndReportsTheMaximum() {
        let link = makeLink(offset: 12)
        link.set(0.9)
        #expect(volume(Self.gripB.uid) == 1)
        #expect(link.isAtMaximum(uid: Self.gripB.uid))
        #expect(!link.isAtMaximum(uid: Self.gripA.uid))
        link.set(0.5)
        #expect(!link.isAtMaximum(uid: Self.gripB.uid))
    }

    @Test func offsetPastTheDecibelCurveTopClamps() {
        let link = makeLink(offset: 12, decibels: -60...0)
        link.set(0.95)
        #expect(volume(Self.gripB.uid) == 1)
        #expect(link.isAtMaximum(uid: Self.gripB.uid))
    }

    // MARK: Storage

    @Test func oldPairJSONDecodesToZeroOffsets() throws {
        let s = try JSONDecoder().decode(PairSettings.self, from: Data(#"{"delayMs":4,"balance":0.2}"#.utf8))
        #expect(s.leftVolumeOffsetDb == 0)
        #expect(s.rightVolumeOffsetDb == 0)
        #expect(s.delayMs == 4)
    }

    @Test func pairOffsetsRoundTripClampAndSwap() throws {
        let s = PairSettings(leftVolumeOffsetDb: 4, rightVolumeOffsetDb: -30)
        #expect(s.rightVolumeOffsetDb == -12)
        let decoded = try JSONDecoder().decode(PairSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
        #expect(s.swapped.leftVolumeOffsetDb == -12)
        #expect(s.swapped.rightVolumeOffsetDb == 4)
    }

    @Test func oldSurroundJSONDecodesToZeroOffsets() throws {
        let s = try JSONDecoder().decode(SurroundSettings.self, from: Data(#"{"width":40,"trims":{"a":0.5}}"#.utf8))
        #expect(s.volumeOffsetsDb.isEmpty)
        #expect(s.volumeOffsetDb(for: "a") == 0)
        #expect(s.trim(for: "a") == 0.5)
    }

    @Test func surroundOffsetsRoundTripAndFollowTheSpeakers() throws {
        var s = SurroundSettings(uids: ["a", "b"])
        s.volumeOffsetsDb = ["a": 5, "b": 40]
        s.sanitize()
        #expect(s.volumeOffsetsDb == ["a": 5, "b": 12])
        let decoded = try JSONDecoder().decode(SurroundSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded.volumeOffsetsDb == s.volumeOffsetsDb)
        #expect(s.carried(to: ["a", "c"]).volumeOffsetsDb == ["a": 5])
    }
}

/// The offset through the model and the Sync & Balance rows.
@MainActor
final class VolumeOffsetModelTests {
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

    @Test func offsetOnAHardwareSpeakerMovesItsVolume() throws {
        hal.add(VolumeOffsetTests.device(VolumeOffsetTests.gripA, volume: 0.5))
        hal.add(VolumeOffsetTests.device(VolumeOffsetTests.gripB, volume: 0.5))
        model.start()
        let right = try #require(model.rightUID)
        let left = try #require(model.leftUID)
        model.setSpeakerVolumeOffset(uid: right, db: 6)
        #expect(model.pairSettings.rightVolumeOffsetDb == 6)
        #expect(hal.volumes(uid: right)[1] == 0.5 + 6 / SpeakerVolumeLink.approximateSpanDb)
        #expect(hal.volumes(uid: left)[1] == 0.5)
        #expect(model.pairSettings.masterVolume == 0.5)
        let row = try #require(model.tuningSheetState.speakerVolume(uid: right))
        #expect(row.readout == "+6 dB")
        #expect(row.note == nil)
    }

    @Test func speakerWithoutHardwareVolumeOnlyTakesACut() throws {
        var fixed = VolumeOffsetTests.gripB
        fixed.volumes = [:]
        hal.add(VolumeOffsetTests.device(VolumeOffsetTests.gripA, volume: 0.5))
        hal.add(fixed)
        model.start()
        let isLeft = model.leftUID == fixed.uid
        func gain() -> Float { isLeft ? model.engine.leftGain : model.engine.rightGain }

        model.setSpeakerVolumeOffset(uid: fixed.uid, db: 6)
        #expect(model.speakerVolumeOffsets[fixed.uid] == 0)
        #expect(gain() == 0.5)

        model.setSpeakerVolumeOffset(uid: fixed.uid, db: -6)
        #expect(abs(gain() - 0.5 * Float(pow(10, -6.0 / 20))) < 0.0001)
        let row = try #require(model.tuningSheetState.speakerVolume(uid: fixed.uid))
        #expect(row.range == -12...0)
        #expect(row.note == "This speaker's volume can't be set from the Mac")
    }
}
