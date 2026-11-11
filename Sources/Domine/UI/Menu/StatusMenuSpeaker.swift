/// One speaker line in the menu bar panel.
struct StatusMenuSpeaker: Equatable, Sendable, Identifiable {
    /// "Front Left", "Speaker" in Single, or a Surround direction.
    var position: String
    /// The device, by UID. Nil while no speaker is chosen.
    var uid: String?
    var deviceName: String
    /// Shown beside the name, since both Grips are called "JBL Grip".
    var uidSuffix: String
    var connection: StatusMenuConnection
    /// 1...100 when the speaker reports it.
    var batteryPercent: Int?
    /// The identification tone is sounding on this speaker.
    var isPlayingTone = false

    /// At this level or below the battery shows in red.
    static let lowBatteryPercent = 15

    var id: String { uid ?? "position:" + position }
    var isConnected: Bool { connection == .connected }
    var isLowBattery: Bool { batteryPercent.map { $0 <= Self.lowBatteryPercent } ?? false }

    /// "JBL Grip (4F2A)": one string, for places that cannot style the parts.
    var deviceLabel: String {
        uidSuffix.isEmpty ? deviceName : "\(deviceName) (\(uidSuffix))"
    }
}

/// The text beside a speaker row's dot.
enum StatusMenuConnection: Equatable, Sendable {
    case connected
    case connecting
    case notConnected
    /// No speaker chosen for this position.
    case unassigned

    var title: String? {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .notConnected: "Not connected"
        case .unassigned: nil
        }
    }
}
