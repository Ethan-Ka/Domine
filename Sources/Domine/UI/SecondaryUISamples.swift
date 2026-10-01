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
        connectedGrips: 1,
        loginItemNeedsApproval: true)

    static let sampleDone = SetupState(
        captureStatus: .working,
        accessibilityGranted: true,
        connectedGrips: 2,
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
    static let sample = StatusMenuState(
        statusText: "Playing",
        isOn: true,
        left: StatusMenuSpeaker(position: "Front Left", deviceName: "JBL Grip", uidSuffix: "4F2A", isConnected: true),
        right: StatusMenuSpeaker(position: "Front Right", deviceName: "JBL Grip", uidSuffix: "9C11", isConnected: true),
        masterVolume: 0.62
    )

    static var sampleLeftOff: StatusMenuState {
        var state = sample
        state.statusText = "Left speaker off"
        state.left.isConnected = false
        return state
    }
}
#endif
