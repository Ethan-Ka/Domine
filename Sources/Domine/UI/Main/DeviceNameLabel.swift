import SwiftUI

/// Device name with its UID suffix as a small tag beside it, so two
/// "JBL Grip"s never show the same label.
struct DeviceNameLabel: View {
    var name: String
    var suffix: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .layoutPriority(1)
            if let suffix {
                Text(suffix)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    .fixedSize()
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    VStack(alignment: .leading) {
        DeviceNameLabel(name: "JBL Grip", suffix: "4F2A")
        DeviceNameLabel(name: "MacBook Pro Speakers", suffix: "Built-in")
    }
    .padding()
}
