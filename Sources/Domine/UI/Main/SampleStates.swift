/// Realistic sample data for previews and render tests: JBL Grips at 62%.
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

    /// One Surround card for a JBL Grip at `azimuth` degrees, 2 m away.
    static func surroundCard(
        _ suffix: String, azimuth: Double, distance: Double = 2, level: Double,
        connection: SpeakerConnection = .connected
    ) -> SpeakerCardState {
        SpeakerCardState.surroundCard(
            SurroundCardInfo(uid: "60-FD-A6-19-\(suffix):output", azimuth: azimuth, distance: distance),
            deviceName: "JBL Grip", uidSuffix: suffix,
            statusText: connection == .connected ? "Connected" : "Not connected",
            connection: connection, level: level)
    }

    /// Five speakers in an ITU-style ring.
    static let surround = MainWindowState(
        statusLine: "Surround",
        isOn: true,
        mode: .surround,
        isSurroundAvailable: true,
        canSwap: false,
        speakers: [
            surroundCard("4F2A", azimuth: -30, level: 0.62),
            surroundCard("9C11", azimuth: 30, level: 0.56),
            surroundCard("5D80", azimuth: 0, distance: 1.6, level: 0.5),
            surroundCard("22B7", azimuth: -110, distance: 2.5, level: 0.4),
            surroundCard("E03D", azimuth: 110, distance: 2.5, level: 0.38),
        ],
        masterVolume: 0.62,
        surround: SurroundControls(width: 30, level: 0.8, orbitRate: 0, rotation: 0, showsBluetoothWarning: true))

    /// The demo orbiting, with the marker behind the listener on the right.
    static let surroundDemo: MainWindowState = {
        var state = SampleStates.surround
        state.surround.orbitRate = 0.25
        state.surround.showsBluetoothWarning = false
        state.demo = DemoState(isPlaying: true, azimuth: 135, sectionTitle: "Orbit")
        return state
    }()

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

    /// "Add Speaker…" in Surround: the sheet adds rather than replaces.
    static let assignSurroundAdd = AssignSheetState(
        position: .frontLeft,
        rows: [
            AssignRow(uid: "60-FD-A6-19-4F-2A:output", name: "JBL Grip", suffix: "4F2A",
                      details: ["Bluetooth", "Placed at -30°"], isSelected: false),
            AssignRow(uid: "60-FD-A6-19-71-C4:output", name: "JBL Grip", suffix: "71C4",
                      details: ["Bluetooth"], isSelected: true),
        ],
        customTitle: "Add a speaker",
        confirmTitle: "Add Speaker")

    static let tuning = TuningState(
        delayMs: 4,
        isExtendedRange: false,
        balance: 0,
        reportedLatencies: "Reported latency: left 182 ms, right 178 ms")
}
