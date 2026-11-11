/// One row of the first-run checklist.
struct WelcomeStep: Identifiable, Equatable, Sendable {
    enum Kind: Int, CaseIterable, Sendable {
        case unpairJBL = 1
        case connectSpeakers
        case allowCapture
        case installDriver

        var title: String {
            switch self {
            case .unpairJBL: "Turn off JBL stereo pairing"
            case .connectSpeakers: "Connect both speakers"
            case .allowCapture: "Allow audio capture"
            case .installDriver: "Install the Domine output (recommended)"
            }
        }

        var detail: String {
            switch self {
            case .unpairJBL:
                "Ungroup the two Grips in the JBL Portable app."
            case .connectSpeakers:
                "Disconnect them from your phone first."
            case .allowCapture:
                "Without it, both speakers stay silent."
            case .installDriver:
                "Lets the volume keys control your speakers. macOS audio restarts for a few seconds."
            }
        }

        var actionTitle: String {
            switch self {
            case .unpairJBL: "Done"
            case .connectSpeakers: "Open Bluetooth"
            case .allowCapture: "Allow…"
            case .installDriver: "Install"
            }
        }
    }

    let kind: Kind
    var isDone: Bool

    var id: Kind { kind }
    var number: Int { kind.rawValue }
}
