import Foundation
import Testing
@testable import Domine

@MainActor
struct SpeakerRoleSettingsTests {
    @Test func oldPairJSONDecodesAsFullRange() throws {
        let json = #"{"delayMs":12,"balance":0.25}"#
        let s = try JSONDecoder().decode(PairSettings.self, from: Data(json.utf8))
        #expect(s.leftRole == .fullRange)
        #expect(s.rightRole == .fullRange)
        #expect(s.crossoverHz == 80)
    }

    @Test func unknownRoleDecodesAsFullRange() throws {
        let json = #"{"leftRole":"tweeter","rightRole":"subwoofer","crossoverHz":500}"#
        let s = try JSONDecoder().decode(PairSettings.self, from: Data(json.utf8))
        #expect(s.leftRole == .fullRange)
        #expect(s.rightRole == .subwoofer)
        #expect(s.crossoverHz == 200)
    }

    @Test func pairRolesRoundTrip() throws {
        let s = PairSettings(leftRole: .satellite, rightRole: .subwoofer, crossoverHz: 120)
        let back = try JSONDecoder().decode(PairSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func swappedPairSwapsTheRoles() {
        let s = PairSettings(leftRole: .satellite, rightRole: .subwoofer, crossoverHz: 100)
        let swapped = s.swapped
        #expect(swapped.leftRole == .subwoofer)
        #expect(swapped.rightRole == .satellite)
        #expect(swapped.crossoverHz == 100)
        #expect(swapped.swapped == s)
    }

    @Test func crossoverIsClamped() {
        #expect(PairSettings(crossoverHz: 10).crossoverHz == 40)
        #expect(PairSettings(crossoverHz: .nan).crossoverHz == 80)
    }

    @Test func oldSurroundJSONDecodesAsFullRange() throws {
        let json = #"{"speakers":[{"uid":"a","azimuth":-30},{"uid":"b","azimuth":30}]}"#
        let s = try JSONDecoder().decode(SurroundSettings.self, from: Data(json.utf8))
        #expect(s.role(for: "a") == .fullRange)
        #expect(s.roles.isEmpty)
        #expect(s.crossoverHz == 80)
    }

    @Test func surroundRolesRoundTripAndCarry() throws {
        var s = SurroundSettings(uids: ["a", "b", "c"])
        s.roles = ["a": .satellite, "c": .subwoofer, "b": .fullRange]
        s.crossoverHz = 300
        s.sanitize()
        #expect(s.roles == ["a": .satellite, "c": .subwoofer])
        #expect(s.crossoverHz == 200)
        let back = try JSONDecoder().decode(SurroundSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let carried = s.carried(to: ["a", "b", "d"])
        #expect(carried.roles == ["a": .satellite])
        #expect(carried.crossoverHz == 200)
    }

    @Test func modelPushesPairRolesToEngine() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let model = AppModel(hal: FakeHAL(), defaults: defaults, services: FakeSystem().services)
        model.updatePairSettings {
            $0.rightRole = .subwoofer
            $0.crossoverHz = 120
        }
        #expect(model.pairSettings.rightRole == .subwoofer)
        #expect(model.engine.crossoverHz == 120)
    }

    @Test func roleRowCaptionAndReadout() {
        #expect(SpeakerRole.crossoverReadout(80) == "80 Hz")
        #expect(SpeakerRole.allCases.map(\.title) == ["Everything", "No deep bass", "Bass only"])
        #expect(SpeakerRole.caption(roles: [.fullRange, .fullRange], hz: 80) == nil)
        #expect(SpeakerRole.caption(roles: [.satellite, .subwoofer], hz: 80) == "Sound below 80 Hz plays only on the bass-only speaker.")
        #expect(SpeakerRole.caption(roles: [.satellite, .satellite], hz: 100) == "No speaker plays the sound below 100 Hz. Set one to Bass only or Everything.")
        #expect(SpeakerRole.caption(roles: [.satellite, .fullRange], hz: 80) == "Speakers set to No deep bass skip the sound below 80 Hz.")
        #expect(SpeakerRole.caption(roles: [.subwoofer, .subwoofer], hz: 80) == "Every speaker is bass only, so nothing plays above 80 Hz.")
        var state = TuningState(delayMs: 0, balance: 0)
        state.speakerRoles = [SpeakerRoleRow(uid: "a", title: "Left", suffix: "4F2A")]
        #expect(!state.isCrossoverEnabled)
        state.speakerRoles[0].role = .satellite
        #expect(state.isCrossoverEnabled)
        #expect(state.speakerRoles[0].label == "Left 4F2A")
    }
}
