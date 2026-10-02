import CoreAudio
import Foundation
import Testing
@testable import Domine

/// The default output follows whether an exclusion is active (SPEC 3b).
@MainActor
final class ExclusionOutputTests {
    static let virtualUID = OutputRestorer.virtualOutputUID

    let hal = FakeHAL()
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let model: AppModel
    let system = FakeSystem()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        model = AppModel(hal: hal, defaults: defaults, services: system.services)
        hal.add(FakeHAL.Device(uid: Self.virtualUID, name: "Domine",
                               transportType: kAudioDeviceTransportTypeVirtual))
        hal.add(OutputRestoreTests.speakers)
        hal.add(OutputRestoreTests.gripA)
        hal.add(OutputRestoreTests.gripB)
        hal.setDefault(uid: OutputRestoreTests.gripA.uid)
        model.start()
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test func activeExclusionMovesTheDefaultToARealOutputAndBack() async {
        await model.startRouting()
        #expect(model.engine.state == .running)
        #expect(hal.defaultOutputUID == Self.virtualUID)

        model.outputRestorer.setExclusionsActive(true)
        #expect(hal.defaultOutputUID == OutputRestoreTests.speakers.uid)

        model.outputRestorer.setExclusionsActive(false)
        #expect(hal.defaultOutputUID == Self.virtualUID)
    }

    @Test func playThroughDeviceIsPreferredWhileActive() async {
        hal.add(OutputRestoreTests.dac)
        model.store.excludedAppsPlayThroughUID = OutputRestoreTests.dac.uid
        await model.startRouting()
        model.outputRestorer.setExclusionsActive(true)
        #expect(hal.defaultOutputUID == OutputRestoreTests.dac.uid)
    }

    @Test func startingWithAnActiveExclusionNeverPicksTheVirtualOutput() async {
        hal.setDefault(uid: Self.virtualUID)
        model.engine.excludedProcesses = [7]
        await model.startRouting()
        #expect(hal.defaultOutputUID == OutputRestoreTests.speakers.uid)
    }
}
