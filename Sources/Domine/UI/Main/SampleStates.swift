/// Realistic sample data for previews and render tests: two JBL Grips at 62%.
enum SampleStates {
    static let frontLeft = SpeakerCardState(
        position: .frontLeft, sideTag: "L", deviceName: "JBL Grip", uidSuffix: "4F2A",
        statusText: "Connected", connection: .connected, level: 0.62)

    static let frontRight = SpeakerCardState(
        position: .frontRight, sideTag: "R", deviceName: "JBL Grip", uidSuffix: "9C11",
        statusText: "Connected", connection: .connected, level: 0.56)

    static let playing = MainWindowState(
        statusLine: "Playing in sync",
        isOn: true,
        speakers: [frontLeft, frontRight],
        masterVolume: 0.62)

    static let quad = MainWindowState(
        statusLine: "Playing",
        isOn: true,
        mode: .quad,
        isQuadAvailable: true,
        speakers: [
            frontLeft, frontRight,
            SpeakerCardState(
                position: .rearLeft, sideTag: "RL", deviceName: "JBL Grip", uidSuffix: "22B7",
                statusText: "Connected", connection: .connected, level: 0.4),
            SpeakerCardState(
                position: .rearRight, sideTag: "RR", deviceName: "JBL Grip", uidSuffix: "E03D",
                statusText: "Connected", connection: .connected, level: 0.38),
        ],
        masterVolume: 0.62)

    static let monoFallback = MainWindowState(
        statusLine: "Mono fallback",
        isOn: true,
        speakers: [
            SpeakerCardState(
                position: .frontLeft, sideTag: "L+R", deviceName: "JBL Grip", uidSuffix: "4F2A",
                statusText: "Mono fallback", connection: .connected, level: 0.7, isMonoFallback: true),
            SpeakerCardState(
                position: .frontRight, sideTag: "R", deviceName: "JBL Grip", uidSuffix: "9C11",
                statusText: "Not connected", connection: .disconnected),
        ],
        masterVolume: 0.62,
        bannerMessage: "Front Right disconnected. Front Left plays both sides until it reconnects.")

    /// Routing on, Front Right dropped out, before the engine has rebuilt
    /// for mono fallback (a moment at most; see monoFallback above).
    static let disconnected = MainWindowState(
        statusLine: "Playing",
        isOn: true,
        speakers: [
            frontLeft,
            SpeakerCardState(
                position: .frontRight, sideTag: "R", deviceName: "JBL Grip", uidSuffix: "9C11",
                statusText: "Not connected", connection: .disconnected),
        ],
        masterVolume: 0.62)

    static let off = MainWindowState(
        statusLine: "Off",
        isOn: false,
        speakers: [
            SpeakerCardState(
                position: .frontLeft, sideTag: "L", deviceName: "JBL Grip", uidSuffix: "4F2A",
                statusText: "Connected", connection: .connected),
            SpeakerCardState(
                position: .frontRight, sideTag: "R", statusText: "Choose a speaker",
                connection: .unassigned),
        ],
        masterVolume: 0.62,
        canPlayTestTones: false)

    static let assign = AssignSheetState(
        position: .frontLeft,
        rows: [
            AssignRow(uid: "60-FD-A6-19-4F-2A:output", name: "JBL Grip", suffix: "4F2A",
                      details: ["Bluetooth"], isSelected: true),
            AssignRow(uid: "60-FD-A6-19-9C-11:output", name: "JBL Grip", suffix: "9C11",
                      details: ["Bluetooth", "In use as Front Right"], isSelected: false),
            AssignRow(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", suffix: "DB08",
                      details: ["Built-in"], isSelected: false),
        ],
        footnote: AppModel.gripPairingHint)

    static let tuning = TuningState(
        delayMs: 4,
        isExtendedRange: false,
        balance: 0,
        reportedLatencies: "Reported latency: left 182 ms, right 178 ms")
}
