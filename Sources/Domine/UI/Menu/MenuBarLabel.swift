import SwiftUI

/// The MenuBarExtra label.
struct MenuBarLabel: View {
    let state: MenuBarLabelState

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: state.showsWarning ? MenuBarIconImage.warning : MenuBarIconImage.normal)
            if let text = state.text {
                Text(text)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.showsWarning ? "Domine, a speaker dropped out" : "Domine")
        .accessibilityValue(state.text ?? "")
    }
}
