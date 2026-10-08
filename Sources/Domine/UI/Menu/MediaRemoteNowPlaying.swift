import Darwin
import Foundation

/// Reads MediaRemote through dlopen. Recent macOS limits this for third-party
/// apps; when symbols are missing or info is empty the source reports nothing.
final class MediaRemoteNowPlaying: NowPlayingSource, @unchecked Sendable {
    private typealias InfoBlock = @convention(block) (CFDictionary?) -> Void
    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping InfoBlock) -> Void
    private typealias Register = @convention(c) (DispatchQueue) -> Void

    private let getInfo: GetInfo?
    private let register: Register?
    private let queue = DispatchQueue(label: "domine.nowplaying")

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let ptr = dlsym(handle, name) else { return nil }
            return unsafeBitCast(ptr, to: type)
        }
        getInfo = symbol("MRMediaRemoteGetNowPlayingInfo", as: GetInfo.self)
        register = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", as: Register.self)
    }

    func current() async -> NowPlayingInfo? {
        guard let getInfo else { return nil }
        return await withCheckedContinuation { continuation in
            let block: InfoBlock = { dict in
                let info = dict as? [String: Any]
                let title = info?["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
                guard !title.isEmpty else { return continuation.resume(returning: nil) }
                let artist = info?["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
                let rate = (info?["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
                continuation.resume(returning: NowPlayingInfo(title: title, artist: artist, isPlaying: rate > 0))
            }
            getInfo(queue, block)
        }
    }

    func send(_ command: NowPlayingCommand) {
        (command == .togglePlayPause ? MediaRemoteCommand.togglePlayPause : .nextTrack).send()
    }

    func observe(_ onChange: @escaping @Sendable () -> Void) {
        guard let register else { return }
        register(queue)
        for name in [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        ] {
            NotificationCenter.default.addObserver(
                forName: Notification.Name(name), object: nil, queue: nil
            ) { _ in onChange() }
        }
    }
}
