import CoreAudio

/// One app that gets its own tap so its volume can differ from the rest.
struct AppTapRequest: Equatable, Sendable {
    /// The app's bundle ID.
    var key: String
    /// The app's Core Audio process objects.
    var processes: [AudioObjectID]
    /// 0 to 1.
    var gain: Double
}
