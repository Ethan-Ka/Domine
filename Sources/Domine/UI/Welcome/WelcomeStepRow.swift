import SwiftUI

/// One checklist step: number or checkmark, title, instruction, action button.
struct WelcomeStepRow: View {
    let step: WelcomeStep
    let action: () -> Void

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.kind.title)
                        .fontWeight(.semibold)
                    Text(step.kind.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(step.kind.actionTitle, action: action)
                    .disabled(step.isDone)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var badge: some View {
        if step.isDone {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white, .green)
                .font(.system(size: 22))
                .accessibilityLabel("Step \(step.number) done")
        } else {
            Image(systemName: "\(step.number).circle")
                .foregroundStyle(.tint)
                .font(.system(size: 22))
                .accessibilityLabel("Step \(step.number)")
        }
    }
}
