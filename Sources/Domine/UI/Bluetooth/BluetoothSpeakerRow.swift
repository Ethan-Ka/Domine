import SwiftUI

/// Speaker icon, name and suffix, an optional status line, and trailing controls.
struct BluetoothSpeakerRow<Controls: View>: View {
    var row: BluetoothSheetRow
    var status: String?
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hifispeaker")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                DeviceNameLabel(name: row.name, suffix: row.suffix)
                if let status {
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if row.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
            controls
                .disabled(row.isBusy)
        }
    }
}
