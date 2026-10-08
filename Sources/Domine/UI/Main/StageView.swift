import AppKit
import SwiftUI

/// The Mac in the center with one card per speaker and a line to each
/// (docs/mockups/Main.dc.html). Scales with the window. In Surround mode
/// it is a top-down room: the listener sits at the Mac, "FRONT" is up, and
/// each card is dragged to where that speaker stands.
struct StageView: View {
    var state: MainWindowState
    var actions: MainWindowActions = .none

    /// The card being dragged and where its speaker was when the drag began.
    @State private var drag: DragAnchor?

    private struct DragAnchor: Equatable {
        var uid: String
        var start: CGPoint
    }

    private static let space = NamedCoordinateSpace.named("stage")
    /// Drags snap to this many degrees unless Option is held.
    static let snapDegrees: Double = 5

    var body: some View {
        GeometryReader { proxy in
            let layout = StageLayout(size: proxy.size, mode: state.mode)
            ZStack(alignment: .topLeading) {
                Circle()
                    .stroke(.quaternary, lineWidth: 1)
                    .frame(width: layout.guideRadius * 2, height: layout.guideRadius * 2)
                    .position(layout.macCenter)

                switch state.mode {
                case .stereo:
                    stereoStage(layout: layout)
                case .surround:
                    surroundStage(layout: layout)
                }

                if state.demo.isPlaying {
                    demoMarker(layout: layout)
                }

                if let banner = state.bannerMessage {
                    StageBanner(message: banner)
                        .frame(width: layout.bannerWidth)
                        .frame(
                            width: layout.size.width,
                            height: max(0, layout.size.height - layout.bannerBottomInset),
                            alignment: .bottom)
                }
            }
            .coordinateSpace(Self.space)
        }
        .background {
            let shape = RoundedRectangle(cornerRadius: 10)
            shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Stereo

    @ViewBuilder
    private func stereoStage(layout: StageLayout) -> some View {
        ForEach(SpeakerPosition.positions(in: .stereo)) { position in
            connector(
                from: layout.connectorStart(position), to: layout.connectorEnd(position),
                connection: state.speaker(at: position).connection)
        }

        thisMac
            .position(x: layout.macCenter.x, y: layout.macCenter.y + 8)

        ForEach(SpeakerPosition.positions(in: .stereo)) { position in
            SpeakerCard(state: state.speaker(at: position)) { actions.selectSpeaker(position) }
                .position(layout.cardCenter(position))
        }
    }

    // MARK: - Surround

    @ViewBuilder
    private func surroundStage(layout: StageLayout) -> some View {
        let cards = state.surroundCards

        ForEach(cards) { card in
            if let info = card.surround {
                let end = layout.surroundConnectorEnd(
                    cardCenter: layout.surroundCardCenter(azimuth: info.azimuth, distance: info.distance))
                connector(from: layout.connectorStart(toward: end), to: end, connection: card.connection)
            }
        }

        // The demo plays with rotation and orbit off, and draws its own marker.
        if !state.demo.isPlaying {
            SoundFieldView(controls: state.surround, layout: layout)
        }

        Text("FRONT")
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)

        thisMac
            .position(x: layout.macCenter.x, y: layout.macCenter.y + 8)

        if cards.isEmpty {
            Text("Add speakers with Add Speaker… or Presets.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .position(x: layout.macCenter.x, y: layout.macCenter.y + 70)
        }

        ForEach(cards) { card in
            if let info = card.surround {
                surroundCard(card, info: info, layout: layout)
            }
        }
    }

    private func surroundCard(_ card: SpeakerCardState, info: SurroundCardInfo, layout: StageLayout) -> some View {
        SpeakerCard(state: card) { actions.chooseSurroundSpeaker(info.uid) }
            .onTapGesture { actions.chooseSurroundSpeaker(info.uid) }
            .gesture(dragGesture(info: info, layout: layout))
            .contextMenu {
                Button("Play Test Tone") { actions.playSurroundTestTone(info.uid) }
                    .disabled(card.connection != .connected)
                Divider()
                Button("Choose Speaker…") { actions.chooseSurroundSpeaker(info.uid) }
                Button("Remove Speaker") { actions.removeSurroundSpeaker(info.uid) }
            }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    move(info, azimuth: info.azimuth + Self.snapDegrees, distance: info.distance)
                case .decrement:
                    move(info, azimuth: info.azimuth - Self.snapDegrees, distance: info.distance)
                @unknown default:
                    break
                }
            }
            .position(layout.surroundCardCenter(azimuth: info.azimuth, distance: info.distance))
    }

    /// Moves the speaker with the pointer. The anchor is the speaker's own
    /// point (not the clamped card center), so dragging toward an edge keeps
    /// adding distance while the card stays inside the stage.
    private func dragGesture(info: SurroundCardInfo, layout: StageLayout) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: Self.space)
            .onChanged { value in
                if drag?.uid != info.uid {
                    drag = DragAnchor(
                        uid: info.uid,
                        start: layout.surroundPoint(azimuth: info.azimuth, distance: info.distance))
                }
                guard let anchor = drag else { return }
                let target = CGPoint(
                    x: anchor.start.x + value.translation.width,
                    y: anchor.start.y + value.translation.height)
                let placement = layout.surroundPlacement(at: target)
                let fine = NSEvent.modifierFlags.contains(.option)
                move(
                    info,
                    azimuth: fine ? placement.azimuth : SurroundCardInfo.snapped(placement.azimuth, step: Self.snapDegrees),
                    distance: fine ? placement.distance : (placement.distance * 10).rounded() / 10)
            }
            .onEnded { _ in drag = nil }
    }

    private func move(_ info: SurroundCardInfo, azimuth: Double, distance: Double) {
        let wrapped = Double(SurroundSpeaker.wrap(Float(azimuth)))
        let range = SurroundSpeaker.distanceRange
        let clamped = min(max(distance, Double(range.lowerBound)), Double(range.upperBound))
        actions.moveSurroundSpeaker(info.uid, wrapped, clamped)
    }

    // MARK: - Shared

    private func demoMarker(layout: StageLayout) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 14, height: 14)
            .shadow(color: Color.accentColor.opacity(0.6), radius: 6)
            .position(layout.demoMarker(azimuth: state.demo.azimuth))
            .animation(.linear(duration: 0.12), value: state.demo.azimuth)
            .accessibilityHidden(true)
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
    private func connector(from start: CGPoint, to end: CGPoint, connection: SpeakerConnection) -> some View {
        let path = Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        switch connection {
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

#Preview("Surround, 5 speakers") {
    StageView(state: SampleStates.surround)
        .frame(width: 616, height: 320)
        .padding()
}

#Preview("Surround, demo") {
    StageView(state: SampleStates.surroundDemo)
        .frame(width: 616, height: 320)
        .padding()
}

#Preview("Mono fallback") {
    StageView(state: SampleStates.monoFallback)
        .frame(width: 616, height: 320)
        .padding()
}
