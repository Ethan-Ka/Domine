import SwiftUI

/// Connection dot, position name, and device label for one speaker.
struct StatusMenuSpeakerRow: View {
    let speaker: StatusMenuSpeaker

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(speaker.isConnected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(speaker.position)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(speaker.deviceName)
                .foregroundStyle(.secondary)
            Text(speaker.uidSuffix)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(speaker.isConnected ? "Connected" : "Not connected")
    }
}
