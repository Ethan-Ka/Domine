import Foundation
import Observation

/// Reconnects Bluetooth speakers that dropped. A missing speaker is tried
/// after 5 seconds, then every 30 seconds, until 10 minutes have passed or it
/// reappears. UIDs that are not Bluetooth addresses are ignored.
@MainActor
@Observable
final class SpeakerReconnector {
    static let firstDelay: Duration = .seconds(5)
    static let retryDelay: Duration = .seconds(30)
    static let giveUpAfter: Duration = .seconds(600)

    /// UIDs with a connection attempt in flight, for the Reconnect button.
    private(set) var connecting: Set<String> = []

    @ObservationIgnored private let connector: any BluetoothConnecting
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    init(
        connector: any BluetoothConnecting,
        isEnabled: @escaping @MainActor () -> Bool,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.connector = connector
        self.isEnabled = isEnabled
        self.sleep = sleep
    }

    /// Call whenever the device list, the assigned speakers, or the setting
    /// changes. `missing` holds assigned UIDs that are not in the catalog.
    func update(missing: Set<String>) {
        let wanted = isEnabled() ? missing.filter { BluetoothAddress(deviceUID: $0) != nil } : []
        for (uid, task) in tasks where !wanted.contains(uid) {
            task.cancel()
            tasks[uid] = nil
        }
        for uid in wanted where tasks[uid] == nil {
            tasks[uid] = Task { [weak self] in await self?.retryLoop(uid: uid) }
        }
    }

    /// One immediate try, from the Reconnect button.
    @discardableResult
    func reconnectNow(uid: String) -> Task<Void, Never> {
        Task { [weak self] in await self?.attempt(uid: uid) }
    }

    /// Waits for every scheduled retry loop to finish. For tests.
    func waitForRetries() async {
        for task in Array(tasks.values) { await task.value }
    }

    private func retryLoop(uid: String) async {
        var elapsed = Duration.zero
        var delay = Self.firstDelay
        while elapsed + delay <= Self.giveUpAfter {
            await sleep(delay)
            if Task.isCancelled { return }
            elapsed += delay
            delay = Self.retryDelay
            guard isEnabled() else { return }
            await attempt(uid: uid)
            if Task.isCancelled { return }
        }
    }

    private func attempt(uid: String) async {
        guard let address = BluetoothAddress(deviceUID: uid), !connecting.contains(uid) else { return }
        connecting.insert(uid)
        _ = await connector.connect(address)
        connecting.remove(uid)
    }
}
