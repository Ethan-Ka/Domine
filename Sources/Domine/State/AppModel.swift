import AppKit
import CoreAudio
import Observation
import os

/// The model every window binds to. Owns the device catalog, the engine,
/// the meters, and the settings store, and turns them into view state.
@MainActor
@Observable
final class AppModel {
    let catalog: DeviceCatalog
    let engine: Engine
    let meters = MeterModel()
    let captureAccess: AudioCapturePermission
    /// Identification tones on a single device while routing is off.
    let tones: DeviceTonePlayer
    @ObservationIgnored let store: SettingsStore
    /// The selected speakers' hardware volumes, kept linked (SPEC 4a).
    @ObservationIgnored let volumeLink: SpeakerVolumeLink
    /// Moves the default output off the pair and back (SPEC 4c).
    @ObservationIgnored let outputRestorer: OutputRestorer

    /// Why the last start request did not route, when the engine was never
    /// asked to start. Shown as the status line while idle.
    private(set) var routingRefusal: String?
    /// The user turned routing off this session. Blocks auto-start until a
    /// selected speaker disconnects and comes back (SPEC 6a).
    @ObservationIgnored var userTurnedRoutingOff = false
    /// Both selected speakers were present at the last catalog sync.
    @ObservationIgnored var bothSpeakersWerePresent = false
    /// The pending auto-start, so tests can wait for it.
    @ObservationIgnored var autoStartTask: Task<Void, Never>?

    /// Selected speakers, by UID. `leftUID` is the Front Left device, which is
    /// always kernel position A. Change them with `setSpeakers(left:right:)`.
    private(set) var leftUID: String?
    private(set) var rightUID: String?
    /// Tuning for the selected pair, seen with `leftUID` as Front Left.
    private(set) var pairSettings = PairSettings()

    /// The position whose Choose Speaker sheet is open.
    var assignPosition: SpeakerPosition?
    /// The radio selection in that sheet.
    var assignSelection: String?
    /// Closing the tuning sheet stops the click test.
    var showsTuning = false {
        didSet { if !showsTuning { stopClickTest() } }
    }
    /// Read from the HAL each time the tuning sheet opens.
    var reportedLatencyText: String?
    /// Why the click test could not start routing, shown in the tuning sheet.
    var clickTestMessage: String?
    /// Starting routing for the click test. Tests await it.
    @ObservationIgnored var clickTestTask: Task<Void, Never>?

    /// First-run checklist sheet.
    var showsWelcome: Bool
    /// The engine reached `.running` at least once this session, so audio
    /// capture was allowed.
    private(set) var hasRunEngine = false
    /// The user pressed Done on the JBL unpairing step.
    var markedJBLUnpaired = false

    /// Settings > General and Exclusions. Edits are written to `store`.
    var generalSettings: GeneralSettingsState {
        didSet {
            generalSettingsDidChange(from: oldValue)
            updateVolumeKeyTap()
        }
    }
    var exclusionsSettings: ExclusionsState {
        didSet { exclusionsDidChange(from: oldValue) }
    }
    @ObservationIgnored let services: SystemServices
    /// The login item waits for approval in System Settings. Re-read with
    /// Accessibility trust in `refreshSystemStatus`.
    var loginItemNeedsApproval = false
    @ObservationIgnored var isRefreshingSystemStatus = false

    static let log = Logger(subsystem: "com.ethankawley.Domine", category: "AppModel")

    /// Last known name per UID, so a disconnected card still shows its name.
    @ObservationIgnored private(set) var knownNames: [String: String] = [:]
    @ObservationIgnored var toneTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    /// Set by the mute key (AppModel+VolumeKeys). Not saved.
    var isMuted = false
    /// The volume key tap and its HUD. Tests replace both.
    @ObservationIgnored var volumeKeyTap: any VolumeKeyTapping = VolumeKeyTap()
    @ObservationIgnored var showVolumeHUD: @MainActor (_ volume: Double, _ isMuted: Bool) -> Void = { volume, muted in
        VolumeHUDPanel.shared.show(volume: volume, isMuted: muted)
    }
    @ObservationIgnored var activationObserver: (any NSObjectProtocol)?
    /// Re-checks Accessibility while volume keys wait for it (AppModel+VolumeKeys).
    @ObservationIgnored var trustPollTask: Task<Void, Never>?
    /// Last reason the volume key tap was not running, so it is logged once.
    @ObservationIgnored var lastVolumeKeyTapBlock: String?
    /// Still not trusted after the user went to System Settings from Grant
    /// Access and came back: the switched-on entry is likely for another
    /// build of Domine (AppModel+Accessibility).
    var accessibilityLikelyStale = false
    /// Grant Access opened System Settings and trust has not arrived yet.
    @ObservationIgnored var awaitingAccessibilityGrant = false
    /// The Settings window is open, so its Accessibility row is on screen.
    @ObservationIgnored var isSettingsVisible = false
    /// How often trust is re-read while a "not granted" note shows.
    @ObservationIgnored var trustPollInterval: Duration = .seconds(2)

    init(hal: any AudioHAL = CoreAudioHAL(), defaults: UserDefaults = .standard,
         services: SystemServices = .live) {
        let store = SettingsStore(defaults: defaults)
        let catalog = DeviceCatalog(hal: hal)
        self.catalog = catalog
        volumeLink = SpeakerVolumeLink(hal: hal)
        outputRestorer = OutputRestorer(hal: hal, store: store, outputs: { catalog.outputs })
        engine = Engine(hal: hal)
        captureAccess = AudioCapturePermission(hal: hal, store: store, signature: services.codeSignature())
        tones = DeviceTonePlayer(hal: hal)
        self.store = store
        self.services = services
        showsWelcome = !store.hasCompletedWelcome
        generalSettings = Self.makeGeneralSettings(store: store, services: services)
        exclusionsSettings = Self.makeExclusionsSettings(store: store, services: services)
        loginItemNeedsApproval = services.launchAtLoginRequiresApproval()
        leftUID = store.lastLeftUID
        rightUID = store.lastRightUID
        pairSettings = Self.loadPairSettings(store: store, left: leftUID, right: rightUID)
        applyPairSettingsToEngine()
        volumeLink.onExternalChange = { [weak self] volume in self?.adoptHardwareVolume(volume) }
    }

    func start() {
        catalog.start()
        if !engine.state.isActive {
            outputRestorer.recoverAfterCrash(enabled: store.restorePreviousOutput)
        }
        syncWithCatalog()
        syncWithEngine()
        guard terminationObserver == nil else { return }
        logPermissionsAtLaunch()
        observeCatalog()
        observeEngine()
        observeActivationForVolumeKeys()
        // Never leave a muting tap behind on quit. AppKit posts this on the
        // main thread; a nil queue runs the block before termination continues.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRouting() }
        }
    }

    // MARK: - Speakers

    /// Picks the two JBL Grips when nothing is selected or restored.
    func chooseDefaultSpeakers() {
        guard leftUID == nil, rightUID == nil else { return }
        let grips = catalog.outputs.filter { $0.name == DeviceCatalog.gripName }
        guard grips.count >= 2 else { return }
        setSpeakers(left: grips[0].uid, right: grips[1].uid)
    }

    /// Selects a pair, saves it, and loads its tuning. A running engine is
    /// rebuilt for the new pair, since a live aggregate is never changed.
    func setSpeakers(left: String?, right: String?) {
        guard left != leftUID || right != rightUID else { return }
        let wasActive = engine.state.isActive
        if wasActive { stopRouting() }
        leftUID = left
        rightUID = right
        routingRefusal = nil
        store.lastLeftUID = left
        store.lastRightUID = right
        pairSettings = Self.loadPairSettings(store: store, left: left, right: right)
        // A new pair is not a speaker connecting, so it never auto-starts.
        bothSpeakersWerePresent = bothSelectedSpeakersPresent
        syncVolumeLink()
        applyPairSettingsToEngine()
        if wasActive {
            Task { await startRouting() }
        }
    }

    func uid(at position: SpeakerPosition) -> String? {
        switch position {
        case .frontLeft: leftUID
        case .frontRight: rightUID
        case .rearLeft, .rearRight: nil
        }
    }

    // MARK: - Routing

    /// The user's on/off switch.
    func setRouting(_ on: Bool) {
        userTurnedRoutingOff = !on
        if on {
            Task { await startRouting() }
        } else {
            stopRouting()
        }
    }

    /// Moves the default output off the pair, links the speaker volumes,
    /// and starts the engine. A start that does not end up routing puts the
    /// previous output back.
    func startRouting() async {
        guard !engine.state.isActive else { return }
        tones.stop()
        routingRefusal = nil
        if let left = leftUID, let right = rightUID, left != right,
           catalog.device(uid: left) != nil, catalog.device(uid: right) != nil {
            do throws(OutputRestorer.Failure) {
                try outputRestorer.prepareForRouting(
                    pair: [left, right], playThroughUID: store.excludedAppsPlayThroughUID)
            } catch .noOtherOutput {
                routingRefusal = Self.noOtherOutputMessage
                syncWithEngine()
                return
            } catch {
                Self.log.error("Could not check the default output: \(String(describing: error), privacy: .public)")
            }
            syncSettingsWithCatalog()
            syncVolumeLink()
            if let volume = volumeLink.relink() { adoptHardwareVolume(volume) }
        }
        applyPairSettingsToEngine()
        await engine.start(left: leftUID, right: rightUID)
        if !engine.state.isActive {
            outputRestorer.restore(enabled: store.restorePreviousOutput)
        }
        syncWithEngine()
    }

    static let noOtherOutputMessage = "No other output for the Mac's own sound; connect one"

    /// The only refusal is `noOtherOutputMessage`; it goes away as soon as
    /// an output outside the pair appears.
    private func clearRefusalIfResolved() {
        guard routingRefusal != nil,
              catalog.outputs.contains(where: { $0.uid != leftUID && $0.uid != rightUID }) else { return }
        routingRefusal = nil
    }

    func stopRouting() {
        stopClickTest()
        cancelTone()
        engine.stop()
        outputRestorer.restore(enabled: store.restorePreviousOutput)
        syncWithEngine()
    }

    func swapSides() {
        engine.swapSides.toggle()
    }

    // MARK: - Tuning and volume

    /// Master volume, 0...1: the hardware volume of both speakers (SPEC 4a).
    /// A speaker without a settable volume gets it as a kernel gain instead.
    func setMasterVolume(_ volume: Double) {
        let value = min(max(Float(volume), 0), 1)
        if volumeLink.volume != nil { volumeLink.set(value) }
        updatePairSettings { $0.masterVolume = value }
    }

    /// Shows a volume read from the speakers as the master value, without
    /// writing it back to them.
    func adoptHardwareVolume(_ volume: Float) {
        updatePairSettings { $0.masterVolume = volume }
    }

    /// Selected speakers that are present, with their current device IDs.
    private var presentSpeakers: [(uid: String, id: AudioObjectID)] {
        var seen = Set<String>()
        return [leftUID, rightUID].compactMap { uid in
            guard let uid, seen.insert(uid).inserted, let device = catalog.device(uid: uid) else { return nil }
            return (uid, device.id)
        }
    }

    var bothSelectedSpeakersPresent: Bool {
        guard let left = leftUID, let right = rightUID, left != right else { return false }
        return catalog.device(uid: left) != nil && catalog.device(uid: right) != nil
    }

    /// Re-attaches the volume link when the present speakers or their IDs
    /// changed. Attaching links both speakers to the lower volume, which
    /// becomes the master value.
    func syncVolumeLink() {
        let present = presentSpeakers
        let current = Dictionary(present.map { ($0.uid, $0.id) }, uniquingKeysWith: { first, _ in first })
        guard current != volumeLink.attachedDevices else { return }
        if present.isEmpty {
            volumeLink.detach()
        } else if let volume = volumeLink.attach(present) {
            adoptHardwareVolume(volume)
        }
        applyPairSettingsToEngine()
    }

    /// Edits the current pair's tuning, saves it, and pushes it to the kernel.
    func updatePairSettings(_ change: (inout PairSettings) -> Void) {
        var s = pairSettings
        change(&s)
        s = PairSettings(delayMs: s.delayMs, extendedRange: s.extendedRange,
                         balance: s.balance, masterVolume: s.masterVolume)
        guard s != pairSettings else { return }
        pairSettings = s
        if let left = leftUID, let right = rightUID, left != right {
            store.setPairSettings(s, leftUID: left, rightUID: right)
        }
        applyPairSettingsToEngine()
    }

    /// Balance is always a kernel gain. Master volume is a kernel gain only
    /// for a speaker whose hardware volume Domine cannot set.
    func applyPairSettingsToEngine() {
        engine.leftGain = pairSettings.leftGain * kernelVolume(for: leftUID)
        engine.rightGain = pairSettings.rightGain * kernelVolume(for: rightUID)
        engine.delayMs = pairSettings.delayMs
    }

    private func kernelVolume(for uid: String?) -> Float {
        if let uid, volumeLink.hasHardwareVolume(uid: uid) { return 1 }
        return pairSettings.masterVolume
    }

    private static func loadPairSettings(store: SettingsStore, left: String?, right: String?) -> PairSettings {
        guard let left, let right, left != right else { return PairSettings() }
        return store.pairSettings(leftUID: left, rightUID: right)
    }

    // MARK: - Test tones

    /// One short tone on the speaker that plays that side: through the engine
    /// while routing (which also checks the routing), otherwise directly on
    /// that speaker. While swapped, the left side is position B.
    func playTestTone(_ side: StereoSide) {
        let onA = (side == .left) != engine.swapSides
        guard engine.state == .running else {
            if let uid = onA ? leftUID : rightUID, catalog.device(uid: uid) != nil {
                tones.play(uid: uid)
            }
            return
        }
        tones.stop()
        playTones([(onA ? .left : .right, DeviceTonePlayer.duration)])
    }

    /// Plays each tone for its duration, then turns the tone off. Only while running.
    func playTones(_ steps: [(TestTone, Duration)]) {
        guard engine.state == .running, let first = steps.first else { return }
        cancelTone()
        engine.testTone = first.0
        toneTask = Task { [weak self] in
            for (index, step) in steps.enumerated() {
                if index > 0 { self?.engine.testTone = step.0 }
                try? await Task.sleep(for: step.1)
                if Task.isCancelled { return }
            }
            self?.engine.testTone = .off
        }
    }

    func cancelTone() {
        toneTask?.cancel()
        toneTask = nil
        engine.testTone = .off
    }

    // MARK: - Reacting to the catalog and engine

    /// Called whenever the output list changes.
    func syncWithCatalog() {
        for device in catalog.outputs { knownNames[device.uid] = device.name }
        clearRefusalIfResolved()
        chooseDefaultSpeakers()
        syncSettingsWithCatalog()
        syncVolumeLink()
        autoStartIfSpeakersConnected()
    }

    /// "Start routing when both speakers connect" (SPEC 6a): starts when both
    /// selected speakers become present while routing is off. After the user
    /// turned routing off, it waits until a speaker disconnects and returns.
    func autoStartIfSpeakersConnected() {
        let present = bothSelectedSpeakersPresent
        let connected = present && !bothSpeakersWerePresent
        bothSpeakersWerePresent = present
        if !present, leftUID != nil, rightUID != nil { userTurnedRoutingOff = false }
        guard connected, store.startWhenBothConnect, !userTurnedRoutingOff, !engine.state.isActive else { return }
        Self.log.info("Both speakers connected; starting routing")
        autoStartTask = Task { [weak self] in await self?.startRouting() }
    }

    /// The main window closed. With "Stop playing" routing stops; with "Keep
    /// playing" it continues and the Dock icon brings the window back.
    func mainWindowDidClose() {
        guard store.closeBehavior == .stopPlaying, engine.state.isActive else { return }
        userTurnedRoutingOff = true
        stopRouting()
    }

    /// Called whenever the engine state changes: meters poll only while running.
    func syncWithEngine() {
        if engine.state == .running {
            if !hasRunEngine { hasRunEngine = true }
            if !meters.isRunning {
                meters.start { [weak self] in self?.readMeterPeaks() ?? (0, 0) }
            }
        } else if meters.isRunning {
            meters.stop()
        }
        if engine.state != .running && engine.clickTest { engine.clickTest = false }
        updateVolumeKeyTap()
    }

    private func observeCatalog() {
        withObservationTracking {
            _ = catalog.outputs
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncWithCatalog()
                self?.observeCatalog()
            }
        }
    }

    private func observeEngine() {
        withObservationTracking {
            _ = engine.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncWithEngine()
                self?.observeEngine()
            }
        }
    }
}
