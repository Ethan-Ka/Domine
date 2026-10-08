import Testing
@testable import Domine

final class FakeNowPlayingSource: NowPlayingSource, @unchecked Sendable {
    var info: NowPlayingInfo?
    private(set) var sent: [NowPlayingCommand] = []
    private var onChange: (@Sendable () -> Void)?

    func current() async -> NowPlayingInfo? { info }
    func send(_ command: NowPlayingCommand) { sent.append(command) }
    func observe(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func fire() { onChange?() }
}

@MainActor
struct NowPlayingTests {
    @Test func hiddenWhenEmpty() async {
        let model = NowPlayingModel(source: FakeNowPlayingSource())
        await model.refresh()
        #expect(model.info == nil)
    }

    @Test func showsTitleAndArtist() async {
        let source = FakeNowPlayingSource()
        source.info = NowPlayingInfo(title: "Song", artist: "Band", isPlaying: false)
        let model = NowPlayingModel(source: source)
        await model.refresh()
        #expect(model.info?.title == "Song")
        #expect(model.info?.artist == "Band")
    }

    @Test func commandsAreForwarded() async {
        let source = FakeNowPlayingSource()
        let model = NowPlayingModel(source: source)
        model.togglePlayPause()
        model.nextTrack()
        #expect(source.sent == [.togglePlayPause, .nextTrack])
    }
}
