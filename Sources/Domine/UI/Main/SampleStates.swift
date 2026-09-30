/// Realistic sample data for previews and render tests: two JBL Grips at 62%.
enum SampleStates {
    static let frontLeft = SpeakerCardState(
        position: .frontLeft, sideTag: "L", deviceName: "JBL Grip", uidSuffix: "4F2A",
        volumePercent: 62, statusText: "Connected", connection: .connected, level: 0.62)

    static let frontRight = SpeakerCardState(
        position: .frontRight, sideTag: "R", deviceName: "JBL Grip", uidSuffix: "9C11",
        volumePercent: 62, statusText: "Connected", connection: .connected, level: 0.56)

    static let playing = MainWindowState(
        statusLine: "Playing in sync",
        isOn: true,
        speakers: [frontLeft, frontRight, .placeholder(.rearLeft), .placeholder(.rearRight)],
        masterVolume: 0.62)

    static let monoFallback = MainWindowState(
        statusLine: "Waiting for Front Right",
        isOn: true,
        speakers: [
            SpeakerCardState(
                position: .frontLeft, sideTag: "L+R", deviceName: "JBL Grip", uidSuffix: "4F2A",
                volumePercent: 62, statusText: "Mono fallback", statusDetail: "Full mix",
                connection: .connected, level: 0.7, isMonoFallback: true),
            SpeakerCardState(
                position: .frontRight, sideTag: "R", deviceName: "JBL Grip", uidSuffix: "9C11",
                statusText: "Off or disconnected", connection: .disconnected),
            .placeholder(.rearLeft),
            .placeholder(.rearRight),
        ],
        masterVolume: 0.62,
        bannerMessage: "Front Right stopped responding. Front Left is playing the full mix in mono until it reconnects, then stereo resumes on its own.")

    static let off = MainWindowState(
        statusLine: "Off",
        isOn: false,
        speakers: [
            SpeakerCardState(
                position: .frontLeft, sideTag: "L", deviceName: "JBL Grip", uidSuffix: "4F2A",
                volumePercent: 62, statusText: "Connected", connection: .connected),
            SpeakerCardState(
                position: .frontRight, sideTag: "R", statusText: "Choose a speaker",
                connection: .unassigned),
        ],
        masterVolume: 0.62)

    static let assign = AssignSheetState(
        position: .frontLeft,
        note: "Both speakers report the name JBL Grip. Play a tone on each to confirm which one is on your left.",
        rows: [
            AssignRow(uid: "60-FD-A6-19-4F-2A:output", name: "JBL Grip", suffix: "4F2A",
                      details: ["Bluetooth", "AAC"], isSelected: true),
            AssignRow(uid: "60-FD-A6-19-9C-11:output", name: "JBL Grip", suffix: "9C11",
                      details: ["In use as Front Right"], isSelected: false),
            AssignRow(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", suffix: "Built-in",
                      details: ["Not recommended with a Bluetooth pair"], isSelected: false),
        ],
        footnote: "Missing a speaker? Turn off JBL stereo pairing in the JBL Portable app, then connect it in Bluetooth settings.")

    static let tuning = TuningState(
        delayMs: 4,
        isExtendedRange: false,
        balance: 0,
        reportedLatencies: "macOS reports 182 ms (Left) and 178 ms (Right). Bluetooth reports are often off, so trust your ears.")
}
