import Foundation
import Observation
import os

/// Sparkle updates (SPEC 8c). Stays off in the unit test host and while the
/// public EdDSA key in Info.plist is still the placeholder, so dev builds
/// never check for or offer updates.
@MainActor
@Observable
final class Updater {
    /// The value of `SPARKLE_PUBLIC_ED_KEY` in project.yml until a real key is set.
    static let placeholderPublicKey = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"

    /// False when updates are off for this build. The menu item and the
    /// Settings checkbox follow it.
    let isEnabled: Bool
    /// A check can start now: the updater is on and no check is running.
    private(set) var canCheckForUpdates = false
    /// Mirrors the driver so SwiftUI sees changes.
    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            driver?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @ObservationIgnored private let driver: UpdaterDriver?

    private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "Updater")

    /// `makeDriver` runs only when updates are on.
    init(publicKey: String?, isTestHost: Bool, makeDriver: () -> UpdaterDriver) {
        if isTestHost {
            driver = nil
        } else if !Self.isUsableKey(publicKey) {
            Self.log.notice("Updates are off: SUPublicEDKey is not set. See README, Releasing.")
            driver = nil
        } else {
            driver = makeDriver()
        }
        isEnabled = driver != nil
        automaticallyChecksForUpdates = driver?.automaticallyChecksForUpdates ?? false
        driver?.start { [weak self] canCheck in
            self?.canCheckForUpdates = canCheck
        }
    }

    /// The updater for the running app, configured from Info.plist.
    static func live() -> Updater {
        Updater(
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            isTestHost: DomineApp.isTestHost,
            makeDriver: { SparkleUpdaterDriver() })
    }

    static func isUsableKey(_ key: String?) -> Bool {
        guard let key = key?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { return false }
        // An unexpanded build setting also counts as missing.
        return key != placeholderPublicKey && !key.hasPrefix("$(")
    }

    func checkForUpdates() {
        guard isEnabled, canCheckForUpdates else { return }
        driver?.checkForUpdates()
    }
}
