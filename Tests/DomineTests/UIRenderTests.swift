import AppKit
import SwiftUI
import Testing
@testable import Domine

/// Renders each view with sample state in light and dark appearance and
/// checks the image is not blank. Uses AppKit's cacheDisplay rather than
/// ImageRenderer so the AppKit-backed controls (segmented control, radio
/// buttons) and the window toolbar render too. Nothing is written unless
/// DOMINE_RENDER_DIR is set (pass TEST_RUNNER_DOMINE_RENDER_DIR to xcodebuild).
@MainActor
struct UIRenderTests {
    static let appearances: [(suffix: String, name: NSAppearance.Name)] = [
        ("light", .aqua),
        ("dark", .darkAqua),
    ]

    @Test func mainWindowPlaying() throws {
        try renderWindow(MainContentView(state: SampleStates.playing), name: "main-playing")
    }

    @Test func mainWindowMonoFallback() throws {
        try renderWindow(MainContentView(state: SampleStates.monoFallback), name: "main-mono-fallback")
    }

    @Test func mainWindowOff() throws {
        try renderWindow(MainContentView(state: SampleStates.off), name: "main-off")
    }

    @Test func mainWindowLarge() throws {
        try renderWindow(
            MainContentView(state: SampleStates.playing), name: "main-large",
            size: CGSize(width: 900, height: 640))
    }

    @Test func assignSheet() throws {
        try renderView(AssignSheet(state: SampleStates.assign), name: "assign")
    }

    @Test func tuningSheet() throws {
        try renderView(TuningSheet(state: SampleStates.tuning), name: "tuning")
    }

    @Test func volumeHUD() throws {
        try renderView(VolumeHUD(volume: 0.62).padding(20), name: "volume-hud")
    }

    // MARK: - Helpers

    /// Hosts the view in a titled window so the toolbar, title, and subtitle
    /// render too. Size is the window's content size including the toolbar.
    private func renderWindow(
        _ view: some View, name: String, size: CGSize = CGSize(width: 640, height: 480)
    ) throws {
        for appearance in Self.appearances {
            let controller = NSHostingController(rootView: view)
            controller.sceneBridgingOptions = [.toolbars, .title]
            let window = OffscreenWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.appearance = NSAppearance(named: appearance.name)
            window.setContentSize(size)
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            window.setContentSize(size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))

            let frameView = try #require(window.contentView?.superview)
            try capture(frameView, name: "\(name)-\(appearance.suffix)")
            window.close()
        }
    }

    private func renderView(_ view: some View, name: String) throws {
        for appearance in Self.appearances {
            let hosting = NSHostingView(
                rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            let window = OffscreenWindow(
                contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.appearance = NSAppearance(named: appearance.name)
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            try capture(hosting, name: "\(name)-\(appearance.suffix)")
            window.close()
        }
    }

    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
        #expect(Self.hasVariedPixels(rep), "\(name) rendered blank")

        if let dir = ProcessInfo.processInfo.environment["DOMINE_RENDER_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #require(rep.representation(using: .png, properties: [:])).write(to: url)
            print("Rendered \(url.path)")
        }
    }

    private static func hasVariedPixels(_ rep: NSBitmapImageRep) -> Bool {
        guard let first = rep.colorAt(x: 0, y: 0) else { return false }
        let stepX = max(rep.pixelsWide / 40, 1)
        let stepY = max(rep.pixelsHigh / 40, 1)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) where rep.colorAt(x: x, y: y) != first {
                return true
            }
        }
        return false
    }
}
