import AppKit
import SwiftUI

/// Stereo / Quad segmented control. Wraps `NSSegmentedControl` because a
/// SwiftUI segmented `Picker` cannot disable a single segment.
struct ModePicker: NSViewRepresentable {
    var selection: RoutingMode
    var isQuadEnabled: Bool
    var onChange: @MainActor (RoutingMode) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: RoutingMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:)))
        control.segmentStyle = .automatic
        control.setContentHuggingPriority(.required, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.onChange = onChange
        for (index, mode) in RoutingMode.allCases.enumerated() {
            control.setEnabled(mode != .quad || isQuadEnabled, forSegment: index)
        }
        control.selectedSegment = RoutingMode.allCases.firstIndex(of: selection) ?? 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onChange: @MainActor (RoutingMode) -> Void

        init(onChange: @escaping @MainActor (RoutingMode) -> Void) {
            self.onChange = onChange
        }

        @objc func changed(_ sender: NSSegmentedControl) {
            let modes = RoutingMode.allCases
            guard modes.indices.contains(sender.selectedSegment) else { return }
            onChange(modes[sender.selectedSegment])
        }
    }
}

#Preview {
    ModePicker(selection: .stereo, isQuadEnabled: false, onChange: { _ in })
        .fixedSize()
        .padding()
}
