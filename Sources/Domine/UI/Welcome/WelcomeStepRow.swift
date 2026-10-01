import SwiftUI

/// One checklist step: number or checkmark, title, instruction, action
/// button, and an optional second button under it.
struct WelcomeStepRow: View {
    let step: WelcomeStep
    var isBusy = false
    var secondaryTitle: String?
    var secondaryAction: () -> Void = {}
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
                VStack(alignment: .trailing, spacing: 6) {
                    Button(step.kind.actionTitle, action: action)
                        .disabled(step.isDone || isBusy)
                    if let secondaryTitle {
                        Button(secondaryTitle, action: secondaryAction)
                    }
                }
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
