import AppKit

/// A window that stays where it is put. AppKit pulls titled windows back
/// onto a screen when they are ordered front, which would show render test
/// windows to the user; this keeps them parked off screen.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
