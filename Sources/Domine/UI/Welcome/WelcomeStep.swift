/// One row of the first-run checklist.
struct WelcomeStep: Identifiable, Equatable, Sendable {
    enum Kind: Int, CaseIterable, Sendable {
        case unpairJBL = 1
        case connectSpeakers
        case allowCapture

        var title: String {
            switch self {
            case .unpairJBL: "Turn off JBL stereo pairing"
            case .connectSpeakers: "Connect both speakers"
            case .allowCapture: "Allow audio capture"
            }
        }

        var detail: String {
            switch self {
            case .unpairJBL:
                "In the JBL Portable app, ungroup the two Grips so the Mac can see each one."
            case .connectSpeakers:
                "Pair each Grip in System Settings › Bluetooth. Disconnect them from your phone."
            case .allowCapture:
                "Domine needs this to route system audio to your speakers."
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
