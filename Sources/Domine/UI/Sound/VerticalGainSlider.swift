import AppKit
import SwiftUI

/// Native vertical NSSlider bound to an EQ band gain. Double-click resets to 0 dB.
struct VerticalGainSlider: NSViewRepresentable {
    var value: Double
    var range: ClosedRange<Double>
    var axLabel: String
    var axValue: String
    var onChange: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSlider {
        let s = NSSlider()
        s.sliderType = .linear
        s.isVertical = true
        s.isContinuous = true
        s.minValue = range.lowerBound
        s.maxValue = range.upperBound
        s.numberOfTickMarks = 3
        s.allowsTickMarkValuesOnly = false
        s.target = context.coordinator
        s.action = #selector(Coordinator.changed(_:))
        return s
    }

    func updateNSView(_ s: NSSlider, context: Context) {
        context.coordinator.parent = self
        Self.apply(value: value, axLabel: axLabel, axValue: axValue, to: s)
    }

    /// Never writes back into the slider during an active drag, and only
    /// touches accessibility strings when they change.
    @MainActor
    static func apply(value: Double, axLabel: String, axValue: String, to s: NSSlider) {
        let dragging = NSApp?.currentEvent?.type == .leftMouseDragged
        if !dragging, s.doubleValue != value { s.doubleValue = value }
        if s.accessibilityLabel() != axLabel { s.setAccessibilityLabel(axLabel) }
        if s.accessibilityValueDescription() != axValue { s.setAccessibilityValueDescription(axValue) }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: VerticalGainSlider?
        @objc func changed(_ sender: NSSlider) {
            if NSApp.currentEvent?.clickCount == 2 { sender.doubleValue = 0 }
            parent?.onChange(sender.doubleValue)
        }
    }
}
