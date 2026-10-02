/// Per-app volume and exclusion from the menu's Apps section.
extension AppModel {
    var statusMenuApps: [StatusMenuApp] {
        appAudio.apps.map { app in
            StatusMenuApp(
                bundleID: app.bundleID,
                name: app.name,
                volume: appVolumes[app.bundleID] ?? 1,
                isExcluded: exclusionsSettings.items.contains {
                    $0.bundleID == app.bundleID && $0.mode == .always
                })
        }
    }

    /// Saves an app's volume, clamped to 0...1. Applies it to the engine
    /// once the mixer is wired in.
    func setAppVolume(bundleID: String, _ volume: Double) {
        let clamped = min(max(volume, 0), 1)
        guard appVolumes[bundleID] != clamped else { return }
        appVolumes[bundleID] = clamped
        store.appVolumes = appVolumes
        applyAppVolumesToEngine()
    }

    /// Seam for the kernel mixer: pushes `appVolumes` to the engine. Does nothing yet.
    func applyAppVolumesToEngine() {}

    /// On: exclude with mode Always. Off: remove the exclusion.
    func setAppExcluded(bundleID: String, _ excluded: Bool) {
        if let index = exclusionsSettings.items.firstIndex(where: { $0.bundleID == bundleID }) {
            if excluded {
                exclusionsSettings.items[index].mode = .always
            } else {
                exclusionsSettings.remove(bundleIDs: [bundleID])
            }
        } else if excluded {
            addExclusion(bundleID: bundleID)
        }
    }
}
