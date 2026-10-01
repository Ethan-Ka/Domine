/// What `AppModel` needs from the volume key tap. `VolumeKeyTap` is the real
/// one; tests pass a fake so they never install a system event tap.
@MainActor
protocol VolumeKeyTapping: AnyObject {
    var isRunning: Bool { get }
    @discardableResult
    func start(handler: @escaping VolumeKeyTap.Handler) -> Bool
    func stop()
}

extension VolumeKeyTap: VolumeKeyTapping {}
