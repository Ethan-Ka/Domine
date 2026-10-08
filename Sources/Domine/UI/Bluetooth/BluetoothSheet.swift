import SwiftUI

/// Connect, pair, and find Bluetooth speakers without System Settings.
struct BluetoothSheet: View {
    var state: BluetoothSheetState
    var actions: BluetoothSheetActions = .none
    @State private var showsOtherPaired = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Bluetooth Speakers")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
            Form {
                mySpeakersSection
                if !state.otherPaired.isEmpty { otherPairedSection }
                nearbySection
            }
            .formStyle(.grouped)
            if let error = state.error {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Done", action: actions.done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 520)
    }

    private var mySpeakersSection: some View {
        Section("My Speakers") {
            if state.mySpeakers.isEmpty {
                Text("No speakers yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(state.mySpeakers) { row in
                BluetoothSpeakerRow(row: row, status: row.isConnected ? "Connected" : "Not connected") {
                    connectButton(row)
                    Button("Forget") { actions.forget(row.address) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Forget \(row.name) \(row.suffix)")
                }
            }
        }
    }

    private var otherPairedSection: some View {
        Section {
            DisclosureGroup("Other Paired Speakers", isExpanded: $showsOtherPaired) {
                ForEach(state.otherPaired) { row in
                    BluetoothSpeakerRow(row: row, status: row.isConnected ? "Connected" : nil) {
                        connectButton(row)
                    }
                }
            }
        }
    }

    private var nearbySection: some View {
        Section {
            if state.nearby.isEmpty, state.hasSearched, !state.isSearching {
                Text("Nothing found. Put the speaker in pairing mode and search again.")
                    .foregroundStyle(.secondary)
            }
            ForEach(state.nearby) { row in
                BluetoothSpeakerRow(row: row) {
                    Button("Pair") { actions.pair(row.address) }
                        .accessibilityLabel("Pair \(row.name) \(row.suffix)")
                }
            }
        } header: {
            HStack {
                Text("Nearby")
                Spacer()
                if state.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Searching")
                    Button("Stop", action: actions.stop)
                } else {
                    Button("Search", action: actions.search)
                }
            }
        }
    }

    private func connectButton(_ row: BluetoothSheetRow) -> some View {
        Group {
            if row.isConnected {
                Button("Disconnect") { actions.disconnect(row.address) }
            } else {
                Button("Connect") { actions.connect(row.address) }
            }
        }
        .accessibilityLabel("\(row.isConnected ? "Disconnect" : "Connect") \(row.name) \(row.suffix)")
    }
}

#if DEBUG
#Preview("Bluetooth") {
    let left = BluetoothAddress(deviceUID: "70-99-1c-11-b9-1c")!
    let right = BluetoothAddress(deviceUID: "70-99-1c-11-4f-2a")!
    let other = BluetoothAddress(deviceUID: "04-52-c7-aa-10-02")!
    let nearby = BluetoothAddress(deviceUID: "70-99-1c-22-30-7e")!
    BluetoothSheet(state: BluetoothSheetState(
        mySpeakers: [
            BluetoothSheetRow(address: left, name: "JBL Grip", isConnected: true, isBusy: false),
            BluetoothSheetRow(address: right, name: "JBL Grip", isConnected: false, isBusy: true),
        ],
        otherPaired: [BluetoothSheetRow(address: other, name: "AirPods Pro", isConnected: false, isBusy: false)],
        nearby: [BluetoothSheetRow(address: nearby, name: "JBL Grip", isConnected: false, isBusy: false)],
        isSearching: true, hasSearched: true,
        error: "Couldn't connect to JBL Grip (B91C)."))
}
#endif
