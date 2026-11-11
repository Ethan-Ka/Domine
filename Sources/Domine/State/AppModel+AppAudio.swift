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

    /// The engine has its most app taps, so another app cannot get its own volume.
    var appVolumeLimitReached: Bool { engine.appTapRequests.count >= Engine.maxAppTaps }

    /// Saves an app's volume, clamped to 0...2 (above 1 boosts it). Applies
    /// it to the engine.
    func setAppVolume(bundleID: String, _ volume: Double) {
        let clamped = min(max(volume, 0), AppTapRequest.maxGain)
        guard appVolumes[bundleID] != clamped else { return }
        appVolumes[bundleID] = clamped
        store.appVolumes = appVolumes
        applyAppVolumesToEngine()
    }

    /// Gives each app with a saved volume other than 100 percent (and not
    /// excluded) its own tap, and pushes the volumes as gains.
    func applyAppVolumesToEngine() {
        let excluded = Set(engine.excludedProcesses)
        let alwaysExcluded = Set(exclusionsSettings.items.filter { $0.mode == .always }.map(\.bundleID))
        let reduced = appVolumes.filter { $0.value != 1 && !alwaysExcluded.contains($0.key) }
        var requests: [AppTapRequest] = []
        // Sorted so a reordered process list is not seen as a change and
        // does not rebuild the tap.
        if !reduced.isEmpty, let processes = try? hal.processObjects() {
            for (bundleID, volume) in reduced {
                let own = processes.filter { process in
                    guard !excluded.contains(process),
                          let id = try? hal.processBundleID(of: process) else { return false }
                    return id == bundleID || id.hasPrefix(bundleID + ".")
                }
                if !own.isEmpty { requests.append(AppTapRequest(key: bundleID, processes: own.sorted(), gain: volume)) }
            }
        }
        engine.setAppTaps(requests)
    }

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
