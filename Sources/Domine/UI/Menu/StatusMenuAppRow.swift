import AppKit
import SwiftUI

/// Icon, name, exclude toggle, and volume slider for one playing app.
struct StatusMenuAppRow: View {
    @Binding var app: StatusMenuApp

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: AppAudioList.icon(bundleID: app.bundleID) ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Exclude", isOn: $app.isExcluded)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Play this app on its normal output")
            }
            HStack(spacing: 8) {
                Slider(value: $app.volume, in: 0...1)
                    .controlSize(.small)
                    .disabled(app.isExcluded)
                    .accessibilityLabel("\(app.name) volume")
                Text("\(Int((app.volume * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.leading, 26)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }
}
