import AppKit
import SwiftUI

/// One app in the exclusions list: icon, name, and mode popup.
struct ExclusionRow: View {
    @Binding var item: ExclusionItem

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: Self.icon(forBundleID: item.bundleID))
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text(item.appName)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Mode", selection: $item.mode) {
                ForEach(ExclusionItem.Mode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Mode for \(item.appName)")
        }
        .padding(.vertical, 2)
        .tag(item.bundleID)
    }

    private static func icon(forBundleID bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
