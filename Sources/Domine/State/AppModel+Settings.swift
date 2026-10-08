/// Settings > General and Settings > Exclusions, backed by `SettingsStore`.
extension AppModel {
    static func makeGeneralSettings(store: SettingsStore, services: SystemServices) -> GeneralSettingsState {
        GeneralSettingsState(
            volumeKeysEnabled: store.volumeKeysEnabled,
            accessibilityGranted: services.isAccessibilityTrusted(),
            restorePreviousOutput: store.restorePreviousOutput,
            previousOutputName: nil,
            closeBehavior: closeBehaviorState(store.closeBehavior),
            startWhenBothConnect: store.startWhenBothConnect,
            launchAtLogin: services.isLaunchAtLoginEnabled(),
            reconnectDroppedSpeakers: store.reconnectDroppedSpeakers)
    }

    static func makeExclusionsSettings(store: SettingsStore, services: SystemServices) -> ExclusionsState {
        let items = store.exclusions.map { exclusion in
            ExclusionItem(
                bundleID: exclusion.bundleID,
                appName: appName(bundleID: exclusion.bundleID, services: services),
                mode: exclusionModeState(exclusion.mode))
        }
        return ExclusionsState(items: items, playThroughDeviceUID: store.excludedAppsPlayThroughUID)
    }

    var generalSettingsActions: GeneralSettingsActions {
        GeneralSettingsActions(grantAccessibility: { [weak self] in self?.grantAccessibility() })
    }

    /// Writes whatever changed in Settings > General to the store.
    func generalSettingsDidChange(from old: GeneralSettingsState) {
        guard !isRefreshingSystemStatus else { return }
        let new = generalSettings
        if new.volumeKeysEnabled != old.volumeKeysEnabled {
            store.volumeKeysEnabled = new.volumeKeysEnabled
            refreshAccessibilityTrust()
        }
        if new.restorePreviousOutput != old.restorePreviousOutput { store.restorePreviousOutput = new.restorePreviousOutput }
        if new.closeBehavior != old.closeBehavior { store.closeBehavior = Self.closeBehavior(new.closeBehavior) }
        if new.startWhenBothConnect != old.startWhenBothConnect { store.startWhenBothConnect = new.startWhenBothConnect }
        if new.reconnectDroppedSpeakers != old.reconnectDroppedSpeakers {
            store.reconnectDroppedSpeakers = new.reconnectDroppedSpeakers
            syncReconnector()
        }
        if new.launchAtLogin != old.launchAtLogin {
            do {
                try services.setLaunchAtLogin(new.launchAtLogin)
                loginItemNeedsApproval = services.launchAtLoginRequiresApproval()
            } catch {
                Self.log.error("Could not change launch at login: \(error.localizedDescription, privacy: .public)")
                refreshSystemStatus()
            }
        }
    }

    /// Writes whatever changed in Settings > Exclusions to the store.
    func exclusionsDidChange(from old: ExclusionsState) {
        let new = exclusionsSettings
        if new.items != old.items {
            store.exclusions = new.items.map { AppExclusion(bundleID: $0.bundleID, mode: Self.exclusionMode($0.mode)) }
            exclusionResolver.update(exclusions: store.exclusions)
        }
        if new.playThroughDeviceUID != old.playThroughDeviceUID {
            store.excludedAppsPlayThroughUID = new.playThroughDeviceUID
            syncSettingsWithCatalog()
        }
    }

    func addExclusion(bundleID: String) {
        exclusionsSettings.add(ExclusionItem(bundleID: bundleID, appName: Self.appName(bundleID: bundleID, services: services)))
    }

    /// Re-reads state the user can change outside Domine: Accessibility
    /// trust and the login item (SMAppService status). Does not write
    /// anything back. Runs when the Settings window opens, when Domine
    /// becomes active, and from the trust poll in AppModel+Accessibility.
    func refreshSystemStatus() {
        isRefreshingSystemStatus = true
        defer { isRefreshingSystemStatus = false }
        refreshAccessibilityTrust()
        let launch = services.isLaunchAtLoginEnabled()
        if generalSettings.launchAtLogin != launch { generalSettings.launchAtLogin = launch }
        let approval = services.launchAtLoginRequiresApproval()
        if loginItemNeedsApproval != approval { loginItemNeedsApproval = approval }
    }

    /// Output lists and names that follow the catalog.
    func syncSettingsWithCatalog() {
        var choices = catalog.outputs.map { ExclusionOutputChoice(uid: $0.uid, name: $0.name) }
        if let saved = exclusionsSettings.playThroughDeviceUID, !choices.contains(where: { $0.uid == saved }) {
            choices.append(ExclusionOutputChoice(uid: saved, name: knownNames[saved] ?? "Output", isConnected: false))
        }
        if exclusionsSettings.outputChoices != choices { exclusionsSettings.outputChoices = choices }
        let previous = store.previousOutputUID.flatMap { catalog.device(uid: $0)?.name }
        if generalSettings.previousOutputName != previous { generalSettings.previousOutputName = previous }
    }

    // MARK: Mapping

    static func closeBehaviorState(_ value: CloseBehavior) -> GeneralSettingsState.CloseBehavior {
        switch value {
        case .keepPlaying: .keepPlaying
        case .stopPlaying: .stopPlaying
        case .stopAndUseMacSpeakers: .stopAndUseMacSpeakers
        }
    }

    static func closeBehavior(_ value: GeneralSettingsState.CloseBehavior) -> CloseBehavior {
        switch value {
        case .keepPlaying: .keepPlaying
        case .stopPlaying: .stopPlaying
        case .stopAndUseMacSpeakers: .stopAndUseMacSpeakers
        }
    }

    static func exclusionModeState(_ mode: AppExclusion.Mode) -> ExclusionItem.Mode {
        switch mode {
        case .always: .always
        case .onlyDuringCalls: .onlyDuringCalls
        }
    }

    static func exclusionMode(_ mode: ExclusionItem.Mode) -> AppExclusion.Mode {
        switch mode {
        case .always: .always
        case .onlyDuringCalls: .onlyDuringCalls
        }
    }

    /// Installed app name, else a suggestion's name, else the bundle ID.
    static func appName(bundleID: String, services: SystemServices) -> String {
        services.appName(bundleID)
            ?? ExclusionsState.defaultSuggestions.first { $0.bundleID == bundleID }?.appName
            ?? bundleID
    }
}
