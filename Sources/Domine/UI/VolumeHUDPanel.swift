import AppKit
import SwiftUI

/// Borderless, non-activating panel that shows `VolumeHUD` near the bottom
/// of the screen with the mouse, like the old system volume overlay
/// (SPEC section 4b). Each `show` resets the timer; the panel fades out
/// about 1.5 s after the last key press.
@MainActor
final class VolumeHUDPanel {
    static let shared = VolumeHUDPanel()

    static let size = CGSize(width: 200, height: 200)
    /// Distance from the bottom of the screen's visible area.
    static let bottomInset: CGFloat = 140
    static let visibleDuration: Duration = .milliseconds(1500)
    static let fadeDuration: TimeInterval = 0.3

    private var panel: NSPanel?
    private var hosting: NSHostingView<VolumeHUD>?
    private var hideTask: Task<Void, Never>?
    /// Bumped by every show, so a fade that finishes late never hides a new HUD.
    private var generation = 0

    private init() {}

    func show(volume: Double, isMuted: Bool) {
        let panel = makePanelIfNeeded()
        hosting?.rootView = VolumeHUD(volume: volume, isMuted: isMuted)
        position(panel)
        generation += 1
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        scheduleHide(generation: generation)
    }

    private func scheduleHide(generation current: Int) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled else { return }
            self?.fadeOut(generation: current)
        }
    }

    private func fadeOut(generation current: Int) {
        guard let panel, generation == current else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    /// Centered horizontally on the screen with the mouse, near its bottom.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let origin = CGPoint(
            x: (area.midX - Self.size.width / 2).rounded(),
            y: (area.minY + Self.bottomInset).rounded())
        panel.setFrame(CGRect(origin: origin, size: Self.size), display: true)
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hosting = NSHostingView(rootView: VolumeHUD(volume: 0))
        hosting.frame = CGRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        self.hosting = hosting
        return panel
    }
}
