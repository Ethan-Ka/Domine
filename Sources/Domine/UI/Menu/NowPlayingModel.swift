import Observation

/// Drives the menu's Now Playing row. `info` is nil whenever the row is hidden.
@MainActor @Observable
final class NowPlayingModel {
    private(set) var info: NowPlayingInfo?
    @ObservationIgnored private let source: NowPlayingSource

    init(source: NowPlayingSource) {
        self.source = source
        source.observe { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        let next = await source.current()
        if next != info { info = next }
    }

    func togglePlayPause() {
        source.send(.togglePlayPause)
        Task { await refresh() }
    }

    func nextTrack() {
        source.send(.nextTrack)
        Task { await refresh() }
    }
}
