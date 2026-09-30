import SwiftUI

/// One position on the stage (docs/mockups/Main.dc.html, Disconnected.dc.html).
struct SpeakerCard: View {
    var state: SpeakerCardState
    var onSelect: @MainActor () -> Void = {}

    static let size = StageLayout.cardSize

    var body: some View {
        switch state.connection {
        case .placeholder:
            placeholder
        case .connected, .disconnected, .unassigned:
            Button(action: onSelect) { card }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
                .accessibilityHint("Choose a speaker for \(state.position.title)")
        }
    }

    private var isError: Bool { state.connection == .disconnected }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(state.connection == .connected ? .primary : .tertiary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(state.position.title)
                            .font(.callout.weight(.semibold))
                        Spacer(minLength: 4)
                        Text(state.sideTag)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isError ? Color.red : Color.accentColor)
                    }
                    if let name = state.deviceName {
                        DeviceNameLabel(name: name, suffix: state.uidSuffix)
                            .font(.callout)
                    }
                    Text(state.statusText)
                        .font(.subheadline)
                        .foregroundStyle(isError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    if let secondary = state.secondaryStatus {
                        Text(secondary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            LevelMeter(level: isError ? 0 : state.level)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(cardBackground)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        switch state.connection {
        case .connected:
            shape.fill(Color(nsColor: .controlBackgroundColor))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
                .shadow(color: Color(nsColor: .shadowColor).opacity(0.08), radius: 1.5, y: 1)
        case .disconnected:
            shape.fill(Color.red.opacity(0.05))
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(shape.strokeBorder(Color.red.opacity(0.35)))
        case .unassigned, .placeholder:
            shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.35))
                .overlay(shape.strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Text(state.position.title)
                .font(.callout.weight(.semibold))
            Text(state.statusText)
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(cardBackground)
        .accessibilityElement(children: .combine)
    }

    private var accessibilityText: String {
        var parts = [state.position.title]
        if let name = state.deviceName {
            parts.append([name, state.uidSuffix].compactMap { $0 }.joined(separator: " "))
        }
        parts.append(state.statusText)
        if let secondary = state.secondaryStatus {
            parts.append(secondary)
        }
        if state.isMonoFallback {
            parts.append("Playing left and right")
        }
        return parts.joined(separator: ", ")
    }
}

#Preview("Connected") {
    SpeakerCard(state: SampleStates.frontLeft).padding()
}

#Preview("Mono fallback and disconnected") {
    HStack {
        SpeakerCard(state: SampleStates.monoFallback.speaker(at: .frontLeft))
        SpeakerCard(state: SampleStates.monoFallback.speaker(at: .frontRight))
    }
    .padding()
}

#Preview("Dark") {
    HStack {
        SpeakerCard(state: SampleStates.frontLeft)
        SpeakerCard(state: SampleStates.monoFallback.speaker(at: .frontRight))
        SpeakerCard(state: .placeholder(.rearLeft))
    }
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}

#Preview("Placeholder and unassigned") {
    HStack {
        SpeakerCard(state: .placeholder(.rearLeft))
        SpeakerCard(state: SampleStates.off.speaker(at: .frontRight))
    }
    .padding()
}
