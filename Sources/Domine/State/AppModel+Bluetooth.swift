/// The Bluetooth Speakers sheet.
extension AppModel {
    var bluetoothSheetState: BluetoothSheetState {
        let model = bluetoothSpeakers
        func rows(_ speakers: [BluetoothSpeaker]) -> [BluetoothSheetRow] {
            speakers.map {
                BluetoothSheetRow(address: $0.address, name: $0.name, isConnected: $0.isConnected,
                                  isBusy: model.busy.contains($0.address.string))
            }
        }
        return BluetoothSheetState(
            mySpeakers: rows(model.mySpeakers), otherPaired: rows(model.otherPaired),
            nearby: rows(model.nearby), isSearching: model.isSearching,
            hasSearched: model.hasSearched, error: model.lastError)
    }

    var bluetoothSheetActions: BluetoothSheetActions {
        let model = bluetoothSpeakers
        return BluetoothSheetActions(
            connect: { address in Task { await model.connect(address) } },
            disconnect: { address in Task { await model.disconnect(address) } },
            pair: { address in Task { await model.pair(address) } },
            forget: { model.forget($0) },
            search: { model.search() },
            stop: { model.stop() },
            done: { [weak self] in self?.closeBluetooth() })
    }

    func openBluetooth() {
        bluetoothSpeakers.lastError = nil
        bluetoothSpeakers.refresh()
        showsBluetooth = true
    }

    func closeBluetooth() {
        bluetoothSpeakers.stop()
        showsBluetooth = false
    }

    /// Adds the Bluetooth ones among these assigned UIDs to My Speakers.
    func rememberBluetoothSpeakers(_ uids: [String?]) {
        for uid in uids.compactMap({ $0 }) {
            let name = knownNames[uid] ?? catalog.device(uid: uid)?.name ?? "Speaker"
            bluetoothSpeakers.remember(uid: uid, name: name)
        }
    }
}
