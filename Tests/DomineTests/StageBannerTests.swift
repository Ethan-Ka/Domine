import Testing
@testable import Domine

/// Which banner the stage shows, and when it says nothing is playing.
struct StageBannerTests {
    private func card(_ position: SpeakerPosition, battery: Int?, level: Double = 0.5,
                      connection: SpeakerConnection = .connected) -> SpeakerCardState {
        var card = SpeakerCardState(
            position: position, sideTag: "L", statusText: "Connected",
            connection: connection, level: level)
        card.batteryPercent = battery
        return card
    }

    private func choose(
        routingFailed: Bool = false, mono: String? = nil, phone: String? = nil,
        keys: Bool = false, speakers: [SpeakerCardState] = [], pairing: String? = nil
    ) -> StageBannerState? {
        StageBannerState.choose(
            routingFailed: routingFailed, monoFallbackText: mono, monoFallbackReconnectUID: "uid",
            phoneTakeoverText: phone, volumeKeysNeedAccessibility: keys,
            speakers: speakers, pairingHint: pairing)
    }

    @Test func nothingToSayGivesNoBanner() {
        #expect(choose(speakers: [card(.frontLeft, battery: 80)]) == nil)
    }

    @Test func errorBeatsEverything() {
        let banner = choose(routingFailed: true, mono: "mono", pairing: "pair")
        #expect(banner?.severity == .error)
        #expect(banner?.action == .reconnect(uid: nil))
    }

    @Test func monoFallbackIsAWarningWithReconnect() {
        let banner = choose(mono: "mono", pairing: "pair")
        #expect(banner?.severity == .warning)
        #expect(banner?.action == .reconnect(uid: "uid"))
    }

    @Test func lowBatteryWarnsAtFifteenPercentOrLess() {
        #expect(choose(speakers: [card(.frontLeft, battery: 16)]) == nil)
        let banner = choose(speakers: [card(.frontLeft, battery: 15)])
        #expect(banner?.severity == .warning)
        #expect(banner?.text == "Front Left battery is at 15%.")
    }

    @Test func lowBatteryOnTwoSpeakersIsOneLine() {
        let banner = choose(speakers: [card(.frontLeft, battery: 10), card(.frontRight, battery: 5)])
        #expect(banner?.text == "2 speakers are low on battery.")
    }

    @Test func disconnectedSpeakerBatteryIsIgnored() {
        #expect(choose(speakers: [card(.frontLeft, battery: 5, connection: .disconnected)]) == nil)
    }

    @Test func pairingHintIsInfoAndOthersOutrankIt() {
        #expect(choose(pairing: "pair")?.severity == .info)
        #expect(choose(keys: true, pairing: "pair")?.action == .openSettings)
    }

    @Test func nothingPlayingNeedsOnAndAllLevelsZero() {
        func state(isOn: Bool, levels: [Double]) -> MainWindowState {
            MainWindowState(
                statusLine: "", isOn: isOn,
                speakers: levels.map { card(.frontLeft, battery: nil, level: $0) },
                masterVolume: 0.5)
        }
        #expect(state(isOn: true, levels: [0, 0]).showsNothingPlaying)
        #expect(!state(isOn: true, levels: [0, 0.2]).showsNothingPlaying)
        #expect(!state(isOn: false, levels: [0, 0]).showsNothingPlaying)
    }
}
