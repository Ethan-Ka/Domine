import Foundation
import Testing
@testable import Domine

@MainActor
final class QuadModelTests {
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let model: AppModel

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        model = AppModel(hal: FakeHAL(), defaults: defaults, services: FakeSystem().services)
    }

    deinit { UserDefaults().removePersistentDomain(forName: suiteName) }

    private func assignAll() {
        for (uid, position) in zip(["A", "B", "C", "D"], SpeakerPosition.allCases) {
            model.assign(uid, to: position)
        }
    }

    @Test func quadNeedsFourDistinctOutputs() {
        #expect(!model.isQuadAvailable)
        model.assign("A", to: .frontLeft)
        model.assign("B", to: .frontRight)
        model.assign("C", to: .rearLeft)
        #expect(!model.isQuadAvailable)
        model.setRoutingMode(.quad)
        #expect(model.routingMode == .quad)
        #expect(model.mainWindowState.speakers.count == 4)
        model.assign("D", to: .rearRight)
        #expect(model.isQuadAvailable)
    }

    @Test func quadSelectableWithTwoSpeakersKeepsStereoRouting() {
        model.assign("A", to: .frontLeft)
        model.assign("B", to: .frontRight)
        model.setRoutingMode(.quad)
        #expect(model.routingMode == .quad)
        #expect(!model.isQuadAvailable)
        #expect(model.mainWindowState.isQuadAvailable)
        model.openAssign(.rearLeft)
        #expect(model.assignPosition == .rearLeft)
        model.assign("C", to: .rearLeft)
        model.assign("D", to: .rearRight)
        #expect(model.isQuadAvailable)
        #expect(model.routingMode == .quad)
    }

    @Test func choosingQuadShowsFourCards() {
        assignAll()
        model.setRoutingMode(.quad)
        #expect(model.routingMode == .quad)
        #expect(model.mainWindowState.speakers.count == 4)
        model.setRoutingMode(.stereo)
        #expect(model.mainWindowState.speakers.count == 2)
    }

    @Test func assigningTakenSpeakerSwaps() {
        assignAll()
        model.assign("A", to: .rearRight)
        #expect(model.rearRightUID == "A")
        #expect(model.leftUID == "D")
        #expect(model.rearLeftUID == "C")
        #expect(model.rightUID == "B")
    }

    @Test func rearSheetOnlyOpensInQuad() {
        assignAll()
        model.openAssign(.rearLeft)
        #expect(model.assignPosition == nil)
        model.setRoutingMode(.quad)
        model.openAssign(.rearLeft)
        #expect(model.assignPosition == .rearLeft)
    }

    @Test func settingsPersistPerSetOfFour() {
        assignAll()
        model.setRoutingMode(.quad)
        model.setRearTrim(0.5)
        model.setRearMode(1)
        let again = AppModel(hal: FakeHAL(), defaults: defaults, services: FakeSystem().services)
        #expect(again.routingMode == .quad)
        #expect(again.rearLeftUID == "C")
        again.assign("A", to: .rearRight)
        #expect(again.quadSettings.rearTrim == 0.5)
        #expect(again.quadSettings.rearMode == 1)
        #expect(again.mainWindowState.rearMode == .matrix)
    }

    @Test func spatialSettingsReachEngineAndPersist() {
        assignAll()
        model.setRoutingMode(.quad)
        #expect(model.quadSettings.spatialAmount == 0.6)
        #expect(model.quadSettings.spatialRoomMs == 15)
        model.setRearMode(3)
        model.setSpatial(amount: 0.3, roomMs: 22)
        #expect(model.engine.rearMode == 3)
        #expect(model.engine.spatialAmount == 0.3)
        #expect(model.engine.spatialRoomMs == 22)
        #expect(model.mainWindowState.spatialAmount == Double(Float(0.3)))
        let again = AppModel(hal: FakeHAL(), defaults: defaults, services: FakeSystem().services)
        again.assign("A", to: .rearRight)
        #expect(again.surroundSettings.spatialRoomMs == 22)
        let old = try? JSONDecoder().decode(QuadSettings.self, from: Data(#"{"rearMode":1}"#.utf8))
        #expect(old?.spatialAmount == 0.6)
    }

    @Test func clearingAFourthSpeakerKeepsQuadModeButStereoRouting() {
        assignAll()
        model.setRoutingMode(.quad)
        model.setRear(left: "C", right: "C")
        #expect(model.routingMode == .quad)
        #expect(!model.isQuadAvailable)
    }
}
