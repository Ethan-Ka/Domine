/// What the menu bar item shows beside its icon (Settings > General).
enum MenuBarContent: String, CaseIterable, Identifiable, Sendable {
    case iconOnly
    case iconAndVolume
    case iconAndMode

    var id: Self { self }

    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .iconAndVolume: "Icon and volume"
        case .iconAndMode: "Icon and mode"
        }
    }
}
