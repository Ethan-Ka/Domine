import Foundation

/// Where the installed Domine output driver stands against the one in the app.
enum DriverStatus: Equatable, Sendable {
    case notInstalled
    case installed
    case updateAvailable

    /// `installed` and `bundled` are CFBundleVersion strings. A device that
    /// Core Audio lists counts as installed even without a readable plist.
    static func make(installed: String?, bundled: String?, devicePresent: Bool) -> DriverStatus {
        guard let installed else { return devicePresent ? .installed : .notInstalled }
        if let bundled, installed.compare(bundled, options: .numeric) == .orderedAscending {
            return .updateAvailable
        }
        return .installed
    }
}

/// A button on the Domine output row.
enum DriverAction: Equatable, Sendable {
    case install
    case update
    case remove

    var buttonTitle: String {
        switch self {
        case .install: "Install"
        case .update: "Update"
        case .remove: "Remove"
        }
    }

    var progressText: String {
        switch self {
        case .install: "Installing…"
        case .update: "Updating…"
        case .remove: "Removing…"
        }
    }

    var confirmTitle: String {
        switch self {
        case .install: "Installing the Domine output restarts macOS audio."
        case .update: "Updating the Domine output restarts macOS audio."
        case .remove: "Removing the Domine output restarts macOS audio."
        }
    }

    var failureText: String {
        switch self {
        case .install: "Could not install the Domine output."
        case .update: "Could not update the Domine output."
        case .remove: "Could not remove the Domine output."
        }
    }

    static let confirmMessage = "Sound stops for a few seconds."
    static let cancelledText = "Cancelled. Nothing changed."
}
