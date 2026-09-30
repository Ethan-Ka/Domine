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
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return false
        }
        guard let key else { return false }
        if key.isKeyDown {
            handler(key)
        }
        return true
    }
}
