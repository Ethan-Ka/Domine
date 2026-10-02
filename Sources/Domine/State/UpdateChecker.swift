import AppKit
import Foundation
import Observation

/// A dotted version such as 1.2.3. Missing parts count as zero.
struct SemanticVersion: Comparable, Equatable, Sendable {
    let parts: [Int]

    init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        if let dash = t.firstIndex(where: { $0 == "-" || $0 == "+" }) { t = String(t[..<dash]) }
        let nums = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !nums.isEmpty, !nums.contains(nil) else { return nil }
        parts = nums.compactMap { $0 }
    }

    static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: SemanticVersion, b: SemanticVersion) -> Bool { !(a < b) && !(b < a) }
}

/// What a check found.
enum UpdateOutcome: Equatable {
    case available(version: String, url: URL)
    case upToDate
    case failed
}

/// Checks GitHub Releases for a newer Domine (SPEC 8c). Updating means
/// downloading and running the installer; nothing is installed here.
@MainActor
@Observable
final class UpdateChecker {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/Ethan-Ka/Domine/releases/latest")!
    static let lastCheckKey = "lastUpdateCheck"
    static let automaticKey = "checkForUpdatesAutomatically"
    static let interval: TimeInterval = 24 * 60 * 60

    /// Mirrors the Settings checkbox, persisted in `defaults`.
    var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: Self.automaticKey) }
    }

    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let fetch: @Sendable (URL) async throws -> Data
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let isTestHost: Bool
    @ObservationIgnored private let present: (UpdateOutcome) -> Void

    init(
        currentVersion: String,
        isTestHost: Bool,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetch: @escaping @Sendable (URL) async throws -> Data,
        present: @escaping (UpdateOutcome) -> Void
    ) {
        self.currentVersion = currentVersion
        self.isTestHost = isTestHost
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        self.present = present
        automaticallyChecks = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    static func live() -> UpdateChecker {
        let checker = UpdateChecker(
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            isTestHost: DomineApp.isTestHost,
            fetch: { url in
                var request = URLRequest(url: url)
                request.setValue("Domine", forHTTPHeaderField: "User-Agent")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                return data
            },
            present: UpdateChecker.showAlert)
        Task { @MainActor in checker.checkAtLaunch() }
        return checker
    }

    /// Runs at launch: at most once per 24 hours, silent unless an update exists.
    func checkAtLaunch() {
        guard !isTestHost, automaticallyChecks else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           now().timeIntervalSince(last) < Self.interval { return }
        defaults.set(now(), forKey: Self.lastCheckKey)
        Task { await run(manual: false) }
    }

    func checkManually() {
        guard !isTestHost else { return }
        Task { await run(manual: true) }
    }

    /// Runs one check and reports the outcome. Exposed for tests.
    func run(manual: Bool) async {
        let outcome = await check()
        switch outcome {
        case .available: present(outcome)
        case .upToDate, .failed: if manual { present(outcome) }
        }
    }

    func check() async -> UpdateOutcome {
        do {
            let data = try await fetch(Self.latestReleaseURL)
            guard let release = try? JSONDecoder().decode(Release.self, from: data),
                  let latest = SemanticVersion(release.tag_name),
                  let current = SemanticVersion(currentVersion) else { return .failed }
            guard current < latest else { return .upToDate }
            let pkg = release.assets.first { $0.name.lowercased().hasSuffix(".pkg") }
            guard let url = URL(string: pkg?.browser_download_url ?? release.html_url) else { return .failed }
            let shown = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            return .available(version: shown, url: url)
        } catch {
            return .failed
        }
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let html_url: String
        let assets: [Asset]
    }

    private static func showAlert(_ outcome: UpdateOutcome) {
        let alert = NSAlert()
        var openURL: URL?
        switch outcome {
        case .available(let version, let url):
            alert.messageText = "Domine \(version) is available."
            alert.informativeText = "Download the installer and run it to update the app and the driver."
            alert.addButton(withTitle: "Download Installer")
            alert.addButton(withTitle: "Later")
            openURL = url
        case .upToDate:
            alert.messageText = "Domine is up to date."
            alert.addButton(withTitle: "OK")
        case .failed:
            alert.messageText = "Could not check for updates."
            alert.informativeText = "Check your internet connection and try again."
            alert.addButton(withTitle: "OK")
        }
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn, let openURL { NSWorkspace.shared.open(openURL) }
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            handle(alert.runModal())
        }
    }
}
