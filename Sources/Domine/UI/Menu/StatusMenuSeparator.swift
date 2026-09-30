import SwiftUI

/// Inset divider between menu sections.
struct StatusMenuSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }
}
