import SwiftUI

/// Full-width rows that highlight on hover, like items in a native menu.
struct StatusMenuItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StatusMenuItemBody(configuration: configuration)
    }
}

private struct StatusMenuItemBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let highlighted = isEnabled && (isHovering || configuration.isPressed)
        configuration.label
            .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
            )
            .onHover { isHovering = $0 }
    }
}
