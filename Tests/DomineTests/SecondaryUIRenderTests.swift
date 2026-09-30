import AppKit
import SwiftUI
import Testing
@testable import Domine

/// Renders the secondary views with sample state to PNGs in the temporary
/// directory for visual checks. Writes nothing into the repo.
@MainActor
struct SecondaryUIRenderTests {
    @Test func rendersGeneralSettings() throws {
        try render(GeneralSettingsView(state: .constant(.sample)), named: "general")
        try render(GeneralSettingsView(state: .constant(.sampleGranted)), named: "general-granted")
    }

    @Test func rendersExclusions() throws {
        try render(ExclusionsView(state: .constant(.sample)), named: "exclusions")
    }

    @Test func rendersSettingsTabs() throws {
        try render(
            SettingsView(general: .constant(.sample), exclusions: .constant(.sample)),
            named: "settings")
    }

    @Test func rendersWelcome() throws {
        try render(WelcomeView(state: .sample), named: "welcome")
    }

    @Test func rendersStatusMenu() throws {
        try render(StatusMenu(state: .constant(.sample)), named: "statusmenu")
        try render(StatusMenu(state: .constant(.sampleLeftOff)), named: "statusmenu-leftoff")
    }

    /// Hosts the view in an offscreen window so AppKit-backed controls
    /// (toggles, popups, lists) draw for real, then snapshots it.
    private func render(_ view: some View, named name: String) throws {
        let host = NSHostingView(rootView: view.background(.windowBackground))
        host.appearance = NSAppearance(named: .aqua)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Domine-\(name).png")
        try data.write(to: url)
        print("Rendered \(name): \(url.path)")
        #expect(size.width > 0 && size.height > 0)
    }
}
