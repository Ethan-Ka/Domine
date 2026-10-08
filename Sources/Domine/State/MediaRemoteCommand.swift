import Darwin
import Foundation

/// MRMediaRemoteSendCommand through dlopen, for the pause watchdog. Uses no AppKit, so the watchdog can call it
/// before any app setup.
enum MediaRemoteCommand: UInt32 {
    // MRMediaRemoteCommand values.
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    /// False when the framework or symbol is missing, or the command was refused.
    @discardableResult
    func send() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let pointer = dlsym(handle, "MRMediaRemoteSendCommand")
        else { return false }
        let sendCommand = unsafeBitCast(pointer, to: SendCommand.self)
        return sendCommand(rawValue, nil)
    }
}
