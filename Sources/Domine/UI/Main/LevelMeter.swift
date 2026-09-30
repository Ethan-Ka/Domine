import SwiftUI

/// 16-segment horizontal peak meter: green, then yellow for the top 3, red
/// for the last 2 (docs/mockups/README.md).
struct LevelMeter: View {
    /// 0...1
    var level: Double

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

    var body: some View {
        let lit = Self.litCount(for: level)
        HStack(spacing: 2) {
            ForEach(0..<Self.segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < lit ? AnyShapeStyle(Self.litColor(at: index)) : AnyShapeStyle(.quaternary))
                    .frame(height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int((min(max(level, 0), 1) * 100).rounded())) percent")
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
