import SwiftUI

/// A message on the stage: a symbol and colour for its severity, the text,
/// an optional button, and a close button when it can be dismissed
/// (docs/mockups/Disconnected.dc.html).
struct StageBanner: View {
    var banner: StageBannerState
    /// The action's work is running; the button shows a progress indicator.
    var isWorking = false
    var onAction: () -> Void = {}
    var onDismiss: () -> Void = {}

    private var tint: Color {
        switch banner.severity {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }

    private var symbol: String {
        switch banner.severity {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(banner.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            actionView
            if banner.isDismissible {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .font(.subheadline)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8)
            shape.fill(Color(nsColor: .controlBackgroundColor))
                .overlay(shape.fill(tint.opacity(banner.severity == .info ? 0 : 0.08)))
                .overlay(shape.strokeBorder(tint.opacity(0.45)))
        }
    }

    @ViewBuilder
    private var actionView: some View {
        switch banner.action {
        case .reconnect:
            if isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                }
            } else {
                Button("Reconnect", action: onAction)
                    .controlSize(.small)
            }
        case .openSettings:
            SettingsLink { Text("Open Settings") }
                .controlSize(.small)
        case nil:
            EmptyView()
        }
    }
}

#Preview("Warning") {
    StageBanner(banner: SampleStates.monoFallback.banner ?? StageBannerState(severity: .warning, text: "Warning"))
        .frame(width: 316)
        .padding()
}

#Preview("Error") {
    StageBanner(banner: StageBannerState(
        severity: .error, text: "Could not start routing", action: .reconnect(uid: nil), isDismissible: false))
        .frame(width: 316)
        .padding()
}

#Preview("Info, dark") {
    StageBanner(banner: StageBannerState(severity: .info, text: "Only one speaker is showing up."))
        .frame(width: 316)
        .padding()
        .preferredColorScheme(.dark)
}
