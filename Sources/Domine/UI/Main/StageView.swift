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
    /// The banner the user closed; it stays away until its text changes.
    @State private var dismissedBannerID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct DragAnchor: Equatable {
        var uid: String
        var start: CGPoint
    }

    private static let space = NamedCoordinateSpace.named("stage")
    /// Drags snap to this many degrees unless Option is held.
    static let snapDegrees: Double = 5

    var body: some View {
        GeometryReader { proxy in
            let layout = StageLayout(size: proxy.size, mode: state.mode, speakerCount: state.mode == .surround ? state.surroundCards.count : 2)
            ZStack(alignment: .topLeading) {
                Circle()
                    .stroke(.quaternary, lineWidth: 1)
                    .frame(width: layout.guideRadius * 2, height: layout.guideRadius * 2)
                    .position(layout.macCenter)

                switch state.mode {
                case .single, .stereo:
                    stereoStage(layout: layout)
                case .surround:
                    surroundStage(layout: layout)
                }

                if state.demo.isPlaying {
                    demoMarker(layout: layout)
                }

                Text("FRONT")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 3)
                    .accessibilityHidden(true)

                if state.showsNothingPlaying {
                    Text("Nothing playing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 10)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: layout.macCenter.x, y: layout.macCenter.y + 78)
                }

                if state.isMuted {
                    Label("Muted", systemImage: "speaker.slash.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 10)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(8)
                }

                if let id = dragCaptionID, let info = dragInfo(id), let text = distanceCaption(info) {
                    Text(text)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(.regularMaterial, in: Capsule())
                        .position(captionPoint(info, layout: layout))
                        .allowsHitTesting(false)
                }

                if !state.isOn {
                    dimmedOverlay
                }

                if let banner = visibleBanner {
                    StageBanner(
                        banner: banner,
                        isWorking: isWorking(banner),
                        onAction: { perform(banner) },
                        onDismiss: { dismissedBannerID = banner.id })
                        .frame(width: layout.bannerWidth)
                        .frame(
                            width: layout.size.width,
                            height: max(0, layout.size.height - layout.bannerBottomInset),
                            alignment: .bottom)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .coordinateSpace(Self.space)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: state.banner?.id)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: state.isOn)
        }
        .background {
            let shape = RoundedRectangle(cornerRadius: 10)
            shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Banner and off state

    private var visibleBanner: StageBannerState? {
        guard let banner = state.banner, banner.id != dismissedBannerID else { return nil }
        return banner
    }

    private func isWorking(_ banner: StageBannerState) -> Bool {
        if case .reconnect(let uid) = banner.action { return state.isReconnecting(uid: uid) }
        return false
    }

    private func perform(_ banner: StageBannerState) {
        guard case .reconnect(let uid) = banner.action else { return }
        if let uid { actions.reconnectSpeaker(uid) } else { actions.setOn(true) }
    }

    /// While Domine is off the stage fades and offers the switch.
    private var dimmedOverlay: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                .allowsHitTesting(false)
            Button("Turn On") { actions.setOn(true) }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .transition(.opacity)
    }

    // MARK: - Stereo

    @ViewBuilder
    private func stereoStage(layout: StageLayout) -> some View {
        ForEach(SpeakerPosition.positions(in: state.mode)) { position in
            connector(
                from: layout.connectorStart(position), to: layout.connectorEnd(position),
                card: state.speaker(at: position))
        }

        thisMac
            .position(x: layout.macCenter.x, y: layout.macCenter.y + 8)

        ForEach(SpeakerPosition.positions(in: state.mode)) { position in
            SpeakerCard(
                state: state.speaker(at: position), compact: layout.isCompact,
                onSelect: { actions.selectSpeaker(position) },
                onReconnect: { state.speaker(at: position).reconnectUID.map(actions.reconnectSpeaker) })
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
                connector(from: layout.connectorStart(toward: end), to: end, card: card)
            }
        }

        // The demo plays with rotation and orbit off, and draws its own marker.
        if !state.demo.isPlaying {
            // Reduce Motion: draw the field still, without the orbit.
            SoundFieldView(
                controls: fieldControls, layout: layout,
                heardPhase: reduceMotion ? { nil } : actions.heardOrbitPhase)
        }

        ringLabels(layout: layout)

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
        SpeakerCard(
            state: card, compact: layout.isCompact,
            onSelect: { actions.chooseSurroundSpeaker(info.uid) },
            onReconnect: { actions.reconnectSpeaker(info.uid) })
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
            .animation(reduceMotion || drag != nil ? nil : .smooth(duration: 0.25),
                       value: layout.surroundCardCenter(azimuth: info.azimuth, distance: info.distance))
    }

    // MARK: - Surround readouts

    private var fieldControls: SurroundControls {
        var controls = state.surround
        if reduceMotion { controls.orbitRate = 0 }
        return controls
    }

    /// "1 m" and "2 m" on faint rings around the Mac.
    private func ringLabels(layout: StageLayout) -> some View {
        ForEach([1.0, 2.0], id: \.self) { metres in
            let radius = layout.surroundRadius(forDistance: metres)
            Circle()
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                .frame(width: radius * 2, height: radius * 2)
                .position(layout.macCenter)
            Text("\(Int(metres)) m")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .position(layout.point(azimuth: 90, radius: radius + 12))
        }
        .accessibilityHidden(true)
    }

    private var dragCaptionID: String? { state.mode == .surround ? drag?.uid : nil }

    private func dragInfo(_ uid: String) -> SurroundCardInfo? {
        state.surroundCards.compactMap(\.surround).first { $0.uid == uid }
    }

    private func distanceCaption(_ info: SurroundCardInfo) -> String? {
        String(format: "%.1f m", info.distance)
    }

    /// Just above the card being dragged, kept inside the stage.
    private func captionPoint(_ info: SurroundCardInfo, layout: StageLayout) -> CGPoint {
        let center = layout.surroundCardCenter(azimuth: info.azimuth, distance: info.distance)
        return CGPoint(x: center.x, y: max(12, center.y - StageLayout.cardSize.height / 2 - 10))
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
            .shadow(color: Color.accentColor.opacity(reduceMotion ? 0 : 0.6), radius: 6)
            .position(layout.demoMarker(azimuth: state.demo.azimuth))
            .animation(reduceMotion ? nil : .linear(duration: 0.12), value: state.demo.azimuth)
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

    /// The line from the Mac to a card. A warning symbol sits mid-line when
    /// the speaker dropped out, and a delayed speaker's "+42 ms" near its card.
    @ViewBuilder
    private func connector(from start: CGPoint, to end: CGPoint, card: SpeakerCardState) -> some View {
        let path = Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        switch card.connection {
        case .connected:
            path.stroke(Color.accentColor.opacity(0.55), lineWidth: 2)
        case .disconnected:
            path.stroke(Color.red.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [3, 5]))
        case .placeholder, .unassigned:
            path.stroke(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 5]))
        }
        if card.connection == .connected {
            if let health = card.health.text {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(3)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .position(Self.point(from: start, to: end, at: 0.45))
                    .help(health)
                    .accessibilityHidden(true)
            }
            if let label = card.sync?.connectorLabel {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .position(Self.point(from: start, to: end, at: 0.75, lift: 9))
                    .accessibilityHidden(true)
            }
        }
    }

    /// A point `t` of the way along the line, moved `lift` points up off it.
    static func point(from start: CGPoint, to end: CGPoint, at t: CGFloat, lift: CGFloat = 0) -> CGPoint {
        CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t - lift)
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
