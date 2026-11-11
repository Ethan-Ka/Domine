#if DEBUG
/// Sample state for previews and render tests: two JBL Grips (4F2A, 9C11)
/// and one exclusion (zoom.us, Only during calls).
extension GeneralSettingsState {
    static let sample = GeneralSettingsState(
        volumeKeysEnabled: true,
        accessibilityGranted: false,
        restorePreviousOutput: true,
        previousOutputName: "MacBook Pro Speakers",
        closeBehavior: .keepPlaying,
        startWhenBothConnect: true,
        launchAtLogin: false
    )

    static var sampleGranted: GeneralSettingsState {
        var state = sample
        state.accessibilityGranted = true
        return state
    }
}

extension SetupState {
    static let sample = SetupState(
        captureStatus: .notConfirmed,
        accessibilityGranted: false,
        connectedSpeakers: 1,
        loginItemNeedsApproval: true)

    static let sampleDone = SetupState(
        captureStatus: .working,
        accessibilityGranted: true,
        connectedSpeakers: 2,
        loginItemNeedsApproval: false)
}

extension ExclusionsState {
    static let sample = ExclusionsState(
        items: [ExclusionItem(bundleID: "us.zoom.xos", appName: "zoom.us", mode: .onlyDuringCalls)],
        playThroughDeviceUID: "BuiltInSpeakerDevice",
        outputChoices: [
            ExclusionOutputChoice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers"),
            ExclusionOutputChoice(uid: "60-FD-A6-19-4F-2A:output", name: "JBL Grip"),
            ExclusionOutputChoice(uid: "60-FD-A6-19-9C-11:output", name: "JBL Grip"),
        ]
    )
}

extension WelcomeState {
    static var sample: WelcomeState {
        var state = WelcomeState()
        state.setDone(.unpairJBL)
        return state
    }
}

extension StatusMenuState {
    static func sampleSpeaker(_ position: String, _ suffix: String, battery: Int? = nil) -> StatusMenuSpeaker {
        StatusMenuSpeaker(
            position: position, uid: "60-FD-A6-19-\(suffix):output", deviceName: "JBL Grip",
            uidSuffix: suffix, connection: .connected, batteryPercent: battery)
    }

    static let sample = StatusMenuState(
        statusText: "Playing",
        isOn: true,
        isSurroundAvailable: true,
        speakers: [
            sampleSpeaker("Front Left", "4F2A", battery: 62),
            sampleSpeaker("Front Right", "9C11", battery: 12),
        ],
        masterVolume: 0.62
    )

    static var sampleWithApps: StatusMenuState {
        var state = sample
        state.apps = [
            StatusMenuApp(bundleID: "com.apple.Music", name: "Music", volume: 0.8),
            StatusMenuApp(bundleID: "us.zoom.xos", name: "zoom.us", volume: 0.5, isExcluded: true),
        ]
        return state
    }

    static var sampleLeftOff: StatusMenuState {
        var state = sample
        state.statusText = "Mono fallback"
        state.speakers[0].connection = .connecting
        state.speakers[0].batteryPercent = nil
        state.speakers[1].isPlayingTone = true
        return state
    }

    static var sampleSingle: StatusMenuState {
        var state = sample
        state.mode = .single
        state.speakers = [sampleSpeaker("Speaker", "4F2A", battery: 80)]
        return state
    }

    static var sampleSurround: StatusMenuState {
        var state = sample
        state.mode = .surround
        state.statusText = "Surround, some speakers missing"
        state.speakers = [
            sampleSpeaker("Front Left", "4F2A", battery: 62),
            sampleSpeaker("Front Right", "9C11", battery: 55),
            sampleSpeaker("Center", "5D80"),
            sampleSpeaker("Rear Left", "22B7", battery: 9),
            sampleSpeaker("Rear Right", "E03D"),
        ]
        state.speakers[4].connection = .notConnected
        return state
    }
}
#endif
