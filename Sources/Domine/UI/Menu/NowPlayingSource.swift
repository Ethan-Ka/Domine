/// What is playing in the system's now playing app.
struct NowPlayingInfo: Equatable, Sendable {
    var title: String
    var artist: String
    var isPlaying: Bool
}

enum NowPlayingCommand: Equatable, Sendable {
    case togglePlayPause
    case nextTrack
}

/// Source of now playing info and transport commands.
protocol NowPlayingSource: Sendable {
    /// Nil when nothing is playing or paused with a title, or the source is unavailable.
    func current() async -> NowPlayingInfo?
    func send(_ command: NowPlayingCommand)
    /// Calls `onChange` whenever the now playing item or state may have changed.
    func observe(_ onChange: @escaping @Sendable () -> Void)
}
