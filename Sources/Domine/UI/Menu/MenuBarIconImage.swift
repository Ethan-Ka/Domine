import AppKit

/// The template images for the menu bar item. The warning variant clears a
/// corner of the icon and puts a small triangle there.
@MainActor
enum MenuBarIconImage {
    static let normal: NSImage = NSImage(named: "MenuBarIcon") ?? NSImage()

    static let warning: NSImage = {
        let base = NSImage(named: "MenuBarIcon")
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .black)
        let badge = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            base?.draw(in: rect)
            guard let badge else { return true }
            let size = badge.size
            let badgeRect = NSRect(x: rect.maxX - size.width, y: rect.minY, width: size.width, height: size.height)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(rect: badgeRect.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            badge.draw(in: badgeRect)
            return true
        }
        image.isTemplate = true
        return image
    }()
}
