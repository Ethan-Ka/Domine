import Foundation

/// Installing, updating and removing the Domine output driver from
/// Settings > General > Setup (SPEC 8d).
extension AppModel {
    var bundledDriverVersion: String? {
        let installer = services.driverInstaller
        return installer.bundledDriverURL.flatMap { installer.version(ofDriverAt: $0) }
    }

    var driverStatus: DriverStatus {
        DriverStatus.make(
            installed: installedDriverVersion, bundled: bundledDriverVersion,
            devicePresent: virtualOutputInstalled)
    }

    func refreshDriverVersion() {
        let version = services.driverInstaller.version(ofDriverAt: DriverPaths.installed)
        if installedDriverVersion != version { installedDriverVersion = version }
    }

    /// Runs one action after the user confirmed it. The password prompt and
    /// the coreaudiod restart happen inside the installer.
    func performDriverAction(_ action: DriverAction) async {
        guard driverActivity == nil else { return }
        let installer = services.driverInstaller
        driverFailure = nil
        driverActivity = action
        defer {
            driverActivity = nil
            refreshDriverVersion()
        }
        do {
            switch action {
            case .install, .update:
                guard let source = installer.bundledDriverURL else { throw DriverInstallError.unavailable }
                try await installer.install(from: source, to: DriverPaths.installed)
            case .remove:
                try await installer.remove(at: DriverPaths.installed)
            }
        } catch DriverInstallError.cancelled {
            driverFailure = DriverAction.cancelledText
        } catch {
            Self.log.error("Driver \(action.buttonTitle, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            driverFailure = action.failureText
        }
    }
}
