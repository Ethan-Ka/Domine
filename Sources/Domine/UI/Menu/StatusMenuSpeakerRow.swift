import SwiftUI

/// One speaker in the menu: position and device on the first line, the
/// connection dot with its status and the battery on the second, and a
/// speaker symbol that animates while the identification tone plays.
struct StatusMenuSpeakerRow: View {
    let speaker: StatusMenuSpeaker

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(speaker.position)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(speaker.deviceLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                    if let status = speaker.connection.title {
                        Text(status)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let percent = speaker.batteryPercent {
                        HStack(spacing: 2) {
                            Image(systemName: SpeakerCard.batterySymbol(percent))
                            Text("\(percent)%")
                                .monospacedDigit()
                        }
                        .foregroundStyle(speaker.isLowBattery ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    }
                }
                .font(.caption)
            }
            Image(systemName: speaker.isPlayingTone ? "speaker.wave.3.fill" : "speaker.wave.2")
                .symbolEffect(.variableColor.iterative, isActive: speaker.isPlayingTone)
                .foregroundStyle(speaker.isPlayingTone ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 20)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var dotColor: Color {
        switch speaker.connection {
        case .connected: .green
        case .connecting: .orange
        case .notConnected, .unassigned: Color.secondary.opacity(0.5)
        }
    }

    private var accessibilityText: String {
        var parts = [speaker.position, speaker.deviceLabel]
        if let status = speaker.connection.title { parts.append(status) }
        if let percent = speaker.batteryPercent { parts.append("Battery \(percent) percent") }
        if speaker.isPlayingTone { parts.append("Playing tone") }
        return parts.joined(separator: ", ")
    }
}
