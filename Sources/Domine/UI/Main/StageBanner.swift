import SwiftUI

/// Warning shown on the stage, e.g. during mono fallback
/// (docs/mockups/Disconnected.dc.html).
struct StageBanner: View {
    var message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8)
            shape.fill(Color(nsColor: .controlBackgroundColor))
                .overlay(shape.strokeBorder(Color.red.opacity(0.35)))
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    StageBanner(message: SampleStates.monoFallback.bannerMessage ?? "")
        .frame(width: 316)
        .padding()
}
