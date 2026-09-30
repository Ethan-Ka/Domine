import AppKit
import SwiftUI

/// A single native radio button. SwiftUI's radio-group `Picker` cannot hold
/// a per-row "Play tone" button, so rows use this instead.
struct RadioButton: NSViewRepresentable {
    var isOn: Bool
    var accessibilityTitle: String
    var action: @MainActor () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            radioButtonWithTitle: "",
            target: context.coordinator,
            action: #selector(Coordinator.clicked))
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.state = isOn ? .on : .off
        button.setAccessibilityLabel(accessibilityTitle)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func clicked() {
            action()
        }
    }
}
