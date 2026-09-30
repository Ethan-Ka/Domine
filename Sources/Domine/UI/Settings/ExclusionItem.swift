/// One app whose audio skips the speaker pair (SPEC 3b).
struct ExclusionItem: Identifiable, Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case always
        case onlyDuringCalls

        var title: String {
            switch self {
            case .always: "Always"
            case .onlyDuringCalls: "Only during calls"
            }
        }
    }

    let bundleID: String
    let appName: String
    var mode: Mode

    var id: String { bundleID }

    init(bundleID: String, appName: String, mode: Mode = .always) {
        self.bundleID = bundleID
        self.appName = appName
        self.mode = mode
    }
}
