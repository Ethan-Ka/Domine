/// An app whose audio bypasses Domine (SPEC section 3b).
struct AppExclusion: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case always
        /// Excluded only while the app has an active input stream.
        case onlyDuringCalls
    }

    var bundleID: String
    var mode: Mode
}
