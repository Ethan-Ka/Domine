import SwiftUI

/// The Mac in the center with one card per position and a line to each
/// (docs/mockups/Main.dc.html). Scales with the window.
struct StageView: View {
    var state: MainWindowState
    var onSelect: @MainActor (SpeakerPosition) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            let layout = StageLayout(size: proxy.size)
            ZStack(alignment: .topLeading) {
                Circle()
                    .stroke(.quaternary, lineWidth: 1)
                    .frame(width: layout.guideRadius * 2, height: layout.guideRadius * 2)
                    .position(layout.macCenter)

                ForEach(SpeakerPosition.allCases) { position in
                    connector(for: state.speaker(at: position), layout: layout)
                }

                Text("FRONT")
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)

                thisMac
                    .position(x: layout.macCenter.x, y: layout.macCenter.y + 8)

                ForEach(SpeakerPosition.allCases) { position in
                    SpeakerCard(state: state.speaker(at: position)) { onSelect(position) }
                        .position(layout.cardCenter(position))
                }

                if let banner = state.bannerMessage {
                    StageBanner(message: banner)
                        .frame(maxWidth: 316)
                        .position(x: layout.size.width / 2, y: layout.size.height - 44)
                }
            }
        }
        .background {
            let shape = RoundedRectangle(cornerRadius: 10)
            shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var thisMac: some View {
        VStack(spacing: 4) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.primary)
            Text("This Mac")
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func connector(for card: SpeakerCardState, layout: StageLayout) -> some View {
        let path = Path { path in
            path.move(to: layout.connectorStart(card.position))
            path.addLine(to: layout.connectorEnd(card.position))
        }
        switch card.connection {
        case .connected:
            path.stroke(Color.accentColor.opacity(0.55), lineWidth: 2)
        case .disconnected:
            path.stroke(Color.red.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [3, 5]))
        case .placeholder, .unassigned:
            path.stroke(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 5]))
        }
    }
}

#Preview("Playing") {
    StageView(state: SampleStates.playing)
        .frame(width: 616, height: 320)
        .padding()
}

#Preview("Mono fallback") {
    StageView(state: SampleStates.monoFallback)
        .frame(width: 616, height: 320)
        .padding()
}
