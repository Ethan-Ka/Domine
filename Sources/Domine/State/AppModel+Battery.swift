import Foundation

extension AppModel {
    /// Re-reads every known speaker's battery. Unknown levels are left out.
    func refreshBatteryLevels() {
        var uids = Set(catalog.outputs.filter(\.isBluetooth).map(\.uid))
        uids.formUnion([leftUID, rightUID].compactMap { $0 })
        uids.formUnion(surroundSpeakers.map(\.uid))
        var levels: [String: Int] = [:]
        for uid in uids {
            guard catalog.device(uid: uid) != nil,
                  let address = BluetoothAddress(deviceUID: uid),
                  let percent = batteryReader.percent(for: address) else { continue }
            levels[uid] = percent
        }
        if levels != batteryPercent { batteryPercent = levels }
    }

    func startBatteryPolling() {
        batteryTask?.cancel()
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                self?.refreshBatteryLevels()
            }
        }
    }
}
