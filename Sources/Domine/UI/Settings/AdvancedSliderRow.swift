import SwiftUI

/// A labelled slider with its value and unit on the right and a one-line
/// caption under it.
struct AdvancedSliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var readout: (Double) -> String
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    Slider(value: $value, in: range, step: step)
                        .labelsHidden()
                        .frame(minWidth: 160)
                    Text(readout(value))
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
            }
            if let caption { AdvancedCaption(text: caption) }
        }
    }
}

/// Secondary text under a setting.
struct AdvancedCaption: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
