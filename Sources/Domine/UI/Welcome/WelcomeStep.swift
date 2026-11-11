/// One row of the first-run checklist.
struct WelcomeStep: Identifiable, Equatable, Sendable {
    enum Kind: Int, CaseIterable, Sendable {
        case unpairJBL = 1
        case connectSpeakers
        case allowCapture

        var title: String {
            switch self {
            case .unpairJBL: "Turn off the speakers' own stereo pairing (for JBL: the JBL Portable app)"
            case .connectSpeakers: "Connect both speakers"
            case .allowCapture: "Let Domine capture your Mac's audio"
            }
        }

        var detail: String {
            switch self {
            case .unpairJBL:
                "Ungroup the two speakers so each one plays on its own."
            case .connectSpeakers:
                "Disconnect them from your phone first."
            case .allowCapture:
                "Domine needs this to send sound to your speakers."
            }
        }

        var actionTitle: String {
            switch self {
            case .unpairJBL: "Done"
            case .connectSpeakers: "Open Bluetooth"
            case .allowCapture: "Allow…"
            }
        }
    }

    let kind: Kind
    var isDone: Bool

    var id: Kind { kind }
    var number: Int { kind.rawValue }
}
