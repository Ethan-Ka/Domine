/// One row of the first-run checklist.
struct WelcomeStep: Identifiable, Equatable, Sendable {
    enum Kind: Int, CaseIterable, Sendable {
        case unpairJBL = 1
        case connectSpeakers
        case allowCapture
        case installDriver

        var title: String {
            switch self {
            case .unpairJBL: "Unpair the speakers in their own app (JBL Portable for JBL)"
            case .connectSpeakers: "Connect your speakers"
            case .allowCapture: "Let Domine capture your Mac's audio"
            case .installDriver: "Install the Domine output (recommended)"
            }
        }

        var detail: String {
            switch self {
            case .unpairJBL:
                "Ungroup the two speakers so each one plays on its own."
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
