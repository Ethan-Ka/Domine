import CoreGraphics

/// State reachable from the C callback through its userInfo pointer. Retained
/// by `VolumeKeyTap` for as long as the tap exists.
@MainActor
final class VolumeKeyTapContext {
    var handler: VolumeKeyTap.Handler
    var port: CFMachPort?

    init(handler: @escaping VolumeKeyTap.Handler) {
        self.handler = handler
    }

    /// Returns true when the event should be swallowed. `key` is the decoded
    /// volume key, or nil when the event is not one.
    func handle(type: CGEventType, key: VolumeKeyEvent?) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            VolumeKeyTap.log.info("Event tap disabled by the system (type \(type.rawValue)); enabling it again")
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return false
        }
        guard let key else { return false }
        // Every half of a volume key press is swallowed, down, repeat, and
        // up alike, so macOS never adjusts its own output while the tap runs.
        VolumeKeyTap.log.info("Swallowed \(String(describing: key.key), privacy: .public) \(key.isKeyDown ? (key.isRepeat ? "repeat" : "down") : "up", privacy: .public)")
        if key.isKeyDown {
            handler(key)
        }
        return true
    }
}
