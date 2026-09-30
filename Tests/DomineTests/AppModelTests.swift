import AppKit
import CoreAudio
import Testing
@testable import Domine

@MainActor
struct AppModelTests {
    let hal = FakeHAL()
    let model: AppModel

    init() {
        model = AppModel(hal: hal)
    }

    @Test func selectsTheTwoGripsByDefault() {
        hal.add(.init(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                      transportType: kAudioDeviceTransportTypeBuiltIn))
        hal.add(EngineTests.gripA)
        hal.add(EngineTests.gripB)
        model.start()
        #expect(model.leftUID == EngineTests.gripA.uid)
        #expect(model.rightUID == EngineTests.gripB.uid)
    }

    @Test func keepsAnExistingSelection() {
        hal.add(EngineTests.gripA)
        hal.add(EngineTests.gripB)
        model.rightUID = EngineTests.gripA.uid
        model.start()
        #expect(model.leftUID == nil)
        #expect(model.rightUID == EngineTests.gripA.uid)
    }

    @Test func terminationStopsTheEngine() async {
        hal.add(EngineTests.gripA)
        hal.add(EngineTests.gripB)
        model.start()
        await model.engine.start(left: model.leftUID, right: model.rightUID)
        #expect(model.engine.state == .running)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(model.engine.state == .idle)
        #expect(hal.liveTapCount == 0)
        #expect(hal.liveAggregateCount == 0)
    }
}
