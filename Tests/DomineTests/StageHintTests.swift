import Foundation
import Testing
@testable import Domine

/// The two stage hints from SPEC section 9: stereo pairing left on, and a
/// phone taking over a speaker.
@MainActor
final class StageHintTests {
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

    @Test func pairingHintShowsWhileOneGripIsMissing() {
        hal.add(EngineTests.gripA)
        model.start()
        model.setSpeakers(left: EngineTests.gripA.uid, right: EngineTests.gripB.uid)
        #expect(model.mainWindowState.bannerMessage == AppModel.gripPairingHint)
        #expect(AppModel.gripPairingHint == "Only one JBL Grip is showing up. If the two are paired to each other in the JBL Portable app, unpair them there.")
        hal.add(EngineTests.gripB)
        model.syncWithCatalog()
        #expect(model.mainWindowState.bannerMessage == nil)
    }

    @Test func phoneHintNamesTheSideOfOneMissingSpeaker() {
        let right = SurroundSpeaker(uid: "r", azimuth: 30)
        let left = SurroundSpeaker(uid: "l", azimuth: -30)
        #expect(AppModel.phoneTakeoverHint(missing: [right])
            == "The right speaker dropped out. A phone connected to it can take over, so check for one.")
        #expect(AppModel.phoneTakeoverHint(missing: [left]).hasPrefix("The left speaker"))
    }

    @Test func phoneHintForSeveralMissingSpeakers() {
        let a = SurroundSpeaker(uid: "a", azimuth: 30)
        let b = SurroundSpeaker(uid: "b", azimuth: -30)
        #expect(AppModel.phoneTakeoverHint(missing: [a, b]).hasPrefix("Some speakers dropped out."))
    }

    @Test func noPhoneHintWhenNotRouting() {
        #expect(model.phoneTakeoverHint == nil)
    }
}
