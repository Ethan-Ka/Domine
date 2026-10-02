import AppKit
import CoreAudio
import Observation
import os

/// An app that is playing audio now. Helper processes are folded into the app.
struct PlayingApp: Equatable, Sendable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/// Apps currently playing audio, from Core Audio process objects whose
/// output is running, grouped by app bundle ID.
@MainActor @Observable
final class AppAudioList {
    private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "AppAudio")

    /// Maps any process bundle ID (an app or a helper of one) to its app's
    /// bundle ID and name. Nil drops the process (daemons, unknown).
    typealias Identify = @MainActor (_ bundleID: String) -> (bundleID: String, name: String)?

    private(set) var apps: [PlayingApp] = []

    @ObservationIgnored private let hal: any AudioHAL
    @ObservationIgnored private let identify: Identify
    @ObservationIgnored private let ownBundleID: String?
    @ObservationIgnored private var listListener: HALListenerToken?
    @ObservationIgnored private var outputTokens: [HALListenerToken] = []

    init(hal: any AudioHAL, ownBundleID: String? = Bundle.main.bundleIdentifier,
         identify: @escaping Identify = AppAudioList.liveIdentify) {
        self.hal = hal
        self.ownBundleID = ownBundleID
        self.identify = identify
    }

    func start() {
        stop()
        do {
            listListener = try hal.addListener(.processObjects) { [weak self] in self?.refresh() }
        } catch {
            Self.log.error("\(error.description, privacy: .public)")
        }
        refresh()
    }

    func stop() {
        listListener?.cancel()
        listListener = nil
        outputTokens.forEach { $0.cancel() }
        outputTokens = []
    }

    /// Re-reads the process list and each process's output state.
    func refresh() {
        outputTokens.forEach { $0.cancel() }
        outputTokens = []
        var found: [String: PlayingApp] = [:]
        do {
            for process in try hal.processObjects() {
                do {
                    outputTokens.append(try hal.addListener(.processIsRunningOutput(process)) { [weak self] in self?.refresh() })
                    guard try hal.processIsRunningOutput(of: process) else { continue }
                    let bundleID = try hal.processBundleID(of: process)
                    guard !bundleID.isEmpty, let app = identify(bundleID),
                          app.bundleID != ownBundleID else { continue }
                    found[app.bundleID] = PlayingApp(bundleID: app.bundleID, name: app.name)
                } catch {
                    // The process went away mid-read, or a listener failed.
                    Self.log.error("\(error.description, privacy: .public)")
                }
            }
        } catch {
            Self.log.error("Could not list audio processes: \(error.description, privacy: .public)")
        }
        let sorted = found.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }
        if sorted != apps { apps = sorted }
    }

    /// Strips trailing components (`com.x.App.helper.Renderer` to `com.x.App`)
    /// until an installed or running app matches.
    static func liveIdentify(_ bundleID: String) -> (bundleID: String, name: String)? {
        var parts = bundleID.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            let candidate = parts.joined(separator: ".")
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) {
                let name = FileManager.default.displayName(atPath: url.path)
                return (candidate, name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
            }
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: candidate).first,
               let name = running.localizedName {
                return (candidate, name)
            }
            parts.removeLast()
        }
        return nil
    }

    static func icon(bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}
