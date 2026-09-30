import SwiftUI

/// Volume overlay shown when the volume keys change Domine's master volume
/// (SPEC section 4b). Only the content; the borderless panel lives elsewhere.
struct VolumeHUD: View {
    /// 0...1
    var volume: Double
    var isMuted: Bool = false

    static let stepCount = 16

    static func litSteps(for volume: Double) -> Int {
        Int((min(max(volume, 0), 1) * Double(stepCount)).rounded())
    }

    var body: some View {
        let lit = isMuted ? 0 : Self.litSteps(for: volume)
        VStack(spacing: 22) {
            Image(systemName: isMuted || lit == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill")
                .font(.system(size: 72, weight: .regular))
                .frame(height: 96)
            HStack(spacing: 1) {
                ForEach(0..<Self.stepCount, id: \.self) { index in
                    Rectangle()
                        .fill(index < lit ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                        .frame(width: 8, height: 7)
                }
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 200, height: 200)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(isMuted ? "Muted" : "\(Int((min(max(volume, 0), 1) * 100).rounded())) percent")
    }
}

#Preview("62%") {
    VolumeHUD(volume: 0.62).padding(40)
}

#Preview("Muted") {
    VolumeHUD(volume: 0.62, isMuted: true).padding(40)
}
