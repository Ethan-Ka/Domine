import SwiftUI

/// M1 placeholder: the live output list. Replaced by the stage layout from
/// docs/mockups/Main.dc.html in a later milestone.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let catalog = model.catalog
        VStack(alignment: .leading, spacing: 0) {
            if catalog.showsGripPairingHint {
                Text("Only one JBL Grip is connected. If the two are stereo-paired, unpair them in the JBL Portable app.")
                    .font(.callout)
                    .padding(12)
            }
            List(catalog.outputs) { device in
                OutputRow(device: device, isDefault: device.uid == catalog.defaultOutputUID)
            }
            .overlay {
                if catalog.outputs.isEmpty {
                    ContentUnavailableView("No output devices", systemImage: "speaker.slash")
                }
            }
            if let error = catalog.lastError {
                Text(error.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
    }
}

private struct OutputRow: View {
    let device: OutputDevice
    let isDefault: Bool

    var body: some View {
        HStack {
            Image(systemName: device.isBluetooth ? "hifispeaker" : "speaker.wave.2")
                .frame(width: 20)
            Text(device.name) + Text(" · \(device.uidSuffix)").foregroundStyle(.secondary)
            Spacer()
            Text("\(device.outputChannels) ch")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if isDefault {
                Text("System output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
