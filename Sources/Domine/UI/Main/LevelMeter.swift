import SwiftUI

/// Peak meter: 16 segments (green, then yellow for the top 3, red for the
/// last 2, docs/mockups/README.md) or a plain bar, with one held peak and a
/// clip latch on the top segment. Style, peak hold and visibility come from
/// Settings > General > Display.
struct LevelMeter: View {
    /// 0...1
    var level: Double

    @AppStorage(SettingsStore.keyPrefix + "meterStyle") private var styleRaw = MeterStyle.segments.rawValue
    @AppStorage(SettingsStore.keyPrefix + "meterPeakHold") private var peakHold = true
    @AppStorage(SettingsStore.keyPrefix + "showMeters") private var showMeters = true
    @State private var hold = MeterPeakHold()

    static let segmentCount = 16

    /// Number of lit segments for a level.
    static func litCount(for level: Double) -> Int {
        Int((min(max(level, 0), 1) * Double(segmentCount)).rounded())
    }

    /// Color of segment `index` (0-based) when lit.
    static func litColor(at index: Int) -> Color {
        switch index {
        case ..<11: .green
        case ..<14: .yellow
        default: .red
        }
    }

    /// Spoken value in dB, for example "-12 decibels". Silence reads "Silent".
    static func accessibilityValue(level: Double, floorDB: Double = MeterBallistics.defaultFloorDB) -> String {
        let clamped = min(max(level, 0), 1)
        guard clamped > 0 else { return "Silent" }
        let db = Int((floorDB + clamped * -floorDB).rounded())
        return db >= 0 ? "0 decibels" : "\(db) decibels"
    }

    private static var now: Double { Date.timeIntervalSinceReferenceDate }

    var body: some View {
        if showMeters {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !hold.isActive(at: Self.now))) { context in
                meter(at: context.date.timeIntervalSinceReferenceDate)
            }
            .onChange(of: level) { _, new in
                hold.update(level: Float(min(max(new, 0), 1)), at: Self.now)
            }
        }
    }

    private func meter(at time: Double) -> some View {
        let clipping = hold.isClipping(at: time)
        let held = peakHold ? Self.litCount(for: Double(hold.held(at: time))) : 0
        return Group {
            if styleRaw == MeterStyle.bar.rawValue {
                barMeter(clipping: clipping, held: held)
            } else {
                segmentMeter(clipping: clipping, held: held)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(clipping ? "Level, clipped" : "Level")
        .accessibilityValue(Self.accessibilityValue(level: level))
        .onTapGesture { hold.clearClip() }
    }

    private func segmentMeter(clipping: Bool, held: Int) -> some View {
        let lit = Self.litCount(for: level)
        return HStack(spacing: 2) {
            ForEach(0..<Self.segmentCount, id: \.self) { index in
                let isTop = index == Self.segmentCount - 1
                let on = index < lit || index == held - 1 || (isTop && clipping)
                RoundedRectangle(cornerRadius: 1)
                    .fill(on ? AnyShapeStyle(Self.litColor(at: index)) : AnyShapeStyle(.quaternary))
                    .frame(height: 6)
            }
        }
    }

    private func barMeter(clipping: Bool, held: Int) -> some View {
        let fraction = min(max(level, 0), 1)
        let heldFraction = Double(held) / Double(Self.segmentCount)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.litColor(at: max(Self.litCount(for: fraction) - 1, 0)))
                    .frame(width: proxy.size.width * fraction)
                if held > 0 {
                    Rectangle()
                        .fill(Self.litColor(at: held - 1))
                        .frame(width: 2)
                        .offset(x: max(proxy.size.width * heldFraction - 2, 0))
                }
                if clipping {
                    RoundedRectangle(cornerRadius: 1).fill(.red)
                        .frame(width: 4)
                        .offset(x: proxy.size.width - 4)
                }
            }
        }
        .frame(height: 6)
    }
}

#Preview {
    VStack(spacing: 12) {
        LevelMeter(level: 0)
        LevelMeter(level: 0.6)
        LevelMeter(level: 0.85)
        LevelMeter(level: 1)
    }
    .padding()
    .frame(width: 176)
}
