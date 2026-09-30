import os

/// Removes a property listener when cancelled or deallocated.
final class HALListenerToken: Sendable {
    private let onCancel: OSAllocatedUnfairLock<(@Sendable () -> Void)?>

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = OSAllocatedUnfairLock(initialState: onCancel)
    }

    func cancel() {
        let action = onCancel.withLock { action in
            defer { action = nil }
            return action
        }
        action?()
    }

    deinit { cancel() }
}
