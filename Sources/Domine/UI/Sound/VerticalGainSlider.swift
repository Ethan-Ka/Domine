import SwiftUI

/// Pure SwiftUI vertical gain control. Drag, arrow keys, accessibility adjust,
/// and double-tap to reset to 0 dB.
struct VerticalGainSlider: View {
    var value: Double
    var range: ClosedRange<Double>
    var axLabel: String
    var axValue: String
    var onChange: (Double) -> Void

    private static let thumbHeight: CGFloat = 14

    /// Maps a y position (0 at top) in a track of `height` to a dB value, top = upper bound.
    static func value(forY y: CGFloat, height: CGFloat, range: ClosedRange<Double>) -> Double {
        let usable = max(1, Double(height - thumbHeight))
        let t = min(1, max(0, (Double(y) - Double(thumbHeight) / 2) / usable))
        let raw = range.upperBound - t * (range.upperBound - range.lowerBound)
        let snapped = (raw * 2).rounded() / 2
        return min(range.upperBound, max(range.lowerBound, snapped))
    }

    private func nudge(_ delta: Double) {
        onChange(min(range.upperBound, max(range.lowerBound, value + delta)))
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let usable = max(1, h - Self.thumbHeight)
            let t = (range.upperBound - value) / (range.upperBound - range.lowerBound)
            let thumbY = Self.thumbHeight / 2 + CGFloat(min(1, max(0, t))) * usable
            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 4)
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Color.secondary)
                    .frame(width: 12, height: 1)
                    .frame(maxWidth: .infinity)
                    .offset(y: h / 2)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlColor))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.6), lineWidth: 1))
                    .frame(width: 20, height: Self.thumbHeight)
                    .frame(maxWidth: .infinity)
                    .offset(y: thumbY - Self.thumbHeight / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { g in
                        let v = Self.value(forY: g.location.y, height: h, range: range)
                        if v != value { onChange(v) }
                    }
            )
            .onTapGesture(count: 2) { onChange(0) }
        }
        .focusable()
        .onKeyPress(.upArrow) { nudge(1); return .handled }
        .onKeyPress(.downArrow) { nudge(-1); return .handled }
        .accessibilityElement()
        .accessibilityLabel(axLabel)
        .accessibilityValue(axValue)
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }
}
