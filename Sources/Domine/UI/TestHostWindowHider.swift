import AppKit
import SwiftUI

/// Content of the main window when the app only hosts unit tests. It takes
/// the window off screen as soon as SwiftUI attaches it.
struct TestHostWindowHider: NSViewRepresentable {
    func makeNSView(context: Context) -> HidingView { HidingView() }
    func updateNSView(_ nsView: HidingView, context: Context) {}

    final class HidingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderOut(nil)
            // SwiftUI orders the window front after attaching its content,
            // so order it out again once that has happened.
            DispatchQueue.main.async { [weak window] in window?.orderOut(nil) }
        }
    }
}
