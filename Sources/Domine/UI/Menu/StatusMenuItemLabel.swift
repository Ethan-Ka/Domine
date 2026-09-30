import SwiftUI

/// A menu-style row: title on the left, shortcut hint on the right.
struct StatusMenuItemLabel: View {
    let title: String
    var shortcut: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut {
                Text(shortcut)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}
