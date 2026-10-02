/// How the rear pair is derived from the stereo input (SPEC 11.5).
enum RearMode: Int, CaseIterable, Identifiable, Sendable {
    case mirror = 0
    case matrix = 1

    var id: Self { self }

    var title: String {
        switch self {
        case .mirror: "Mirror"
        case .matrix: "Matrix"
        }
    }
}
