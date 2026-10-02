import AppKit
import CoreAudio
import DomineDSP
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
    /// Rear speakers, for quad mode (SPEC 11). Change with `setRear(left:right:)`.
    private(set) var rearLeftUID: String?
    private(set) var rearRightUID: String?
    /// The Stereo / Quad control. Quad only routes once the engine supports it.
    private(set) var routingMode: RoutingMode = .stereo
    /// Tuning for the current set of four speakers.
    private(set) var quadSettings = QuadSettings()
    /// The engine and kernel play four speakers (SPEC 11, phase 2).
    nonisolated static let engineSupportsQuad = true
    /// Tuning for the selected pair, seen with `leftUID` as Front Left.
    private(set) var pairSettings = PairSettings()

    /// Saved speaker setups. `currentRoomID` is the one matching the current setup.
    var rooms: [Room] = []
    var currentRoomID: UUID?
    var showsSaveRoom = false
    var showsManageRooms = false

    /// The position whose Choose Speaker sheet is open.
    var assignPosition: SpeakerPosition?
    /// The radio selection in that sheet.
    var assignSelection: String?
    /// Closing the tuning sheet stops the click test.
    var showsSound = false
    var showsTuning = false {
        didSet { if !showsTuning { stopClickTest(); cancelCalibration() } }
    }
    /// Read from the HAL each time the tuning sheet opens.
    var reportedLatencyText: String?
    /// Why the click test could not start routing, shown in the tuning sheet.
    var clickTestMessage: String?
    /// Starting routing for the click test. Tests await it.
    @ObservationIgnored var clickTestTask: Task<Void, Never>?
    @ObservationIgnored let calibration: CalibrationController
    var calibrationStatus: CalibrationStatus?
    /// Whether a built-in microphone exists; read when the tuning sheet opens.
    var isCalibrationAvailable = false
    @ObservationIgnored var calibrationTask: Task<Void, Never>?

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
    @ObservationIgnored let sleepState = SleepState()
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    /// The main window is closed and routing goes on, with a menu bar item
    /// and no Dock icon (SPEC 6a). Change it only through `enterBackground()`
    /// and `leaveBackground()` in AppModel+Background, which set the policy.
    var isInBackground = false
    /// Opens the main window scene. Set by the views, which hold `openWindow`.
    @ObservationIgnored var presentMainWindow: @MainActor () -> Void = {}

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
    @ObservationIgnored let hal: any AudioHAL
    /// Follows the Domine virtual output's volume and mute (AppModel+VirtualOutput).
    @ObservationIgnored var virtualOutput: VirtualOutputLink?
    /// Resolves excluded apps to process objects for the tap (SPEC 3b).
    @ObservationIgnored let exclusionResolver: ExclusionResolver

    init(hal: any AudioHAL = CoreAudioHAL(), defaults: UserDefaults = .standard,
         services: SystemServices = .live) {
        let store = SettingsStore(defaults: defaults)
        self.hal = hal
        let catalog = DeviceCatalog(hal: hal)
        self.catalog = catalog
        volumeLink = SpeakerVolumeLink(hal: hal)
        outputRestorer = OutputRestorer(hal: hal, store: store, outputs: { catalog.outputs })
        engine = Engine(hal: hal)
        exclusionResolver = ExclusionResolver(hal: hal)
        captureAccess = AudioCapturePermission(hal: hal, store: store, signature: services.codeSignature())
        tones = DeviceTonePlayer(hal: hal)
        calibration = CalibrationController(hal: hal)
        self.store = store
        self.services = services
        showsWelcome = !store.hasCompletedWelcome
        generalSettings = Self.makeGeneralSettings(store: store, services: services)
        exclusionsSettings = Self.makeExclusionsSettings(store: store, services: services)
        loginItemNeedsApproval = services.launchAtLoginRequiresApproval()
        leftUID = store.lastLeftUID
        rightUID = store.lastRightUID
        rearLeftUID = store.lastRearLeftUID
        rearRightUID = store.lastRearRightUID
        routingMode = store.routingMode
        rooms = store.rooms
        currentRoomID = store.currentRoomID.flatMap { id in rooms.contains { $0.id == id } ? id : nil }
        pairSettings = Self.loadPairSettings(store: store, left: leftUID, right: rightUID)
        applyPairSettingsToEngine()
        volumeLink.onExternalChange = { [weak self] volume in self?.adoptHardwareVolume(volume) }
        engine.onRoutingEnded = { [weak self] in self?.engineEndedRouting() }
        let engine = engine
        exclusionResolver.onChange = { [weak self] processes in
            self?.outputRestorer.setExclusionsActive(!processes.isEmpty)
            self?.syncVirtualOutput()
            await engine.setExcludedProcesses(processes)
        }
    }

    func start() {
        StaleAggregateCleaner.clean(hal: hal)
        if engine.state.isActive {
            _ = exclusionResolver.start(exclusions: store.exclusions)
        } else {
            engine.excludedProcesses = exclusionResolver.start(exclusions: store.exclusions)
        }
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
        observeSleepAndWake()
        // Never leave a muting tap behind on quit. AppKit posts this on the
        // main thread; a main-queue observer posted from the main thread runs inline.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillTerminate() }
        }
    }

    // MARK: - Speakers

    /// Picks the two JBL Grips when nothing is selected or restored.
    func chooseDefaultSpeakers() {
        guard leftUID == nil, rightUID == nil else { return }
        let grips = catalog.outputs.filter { $0.name == DeviceCatalog.gripName }
        guard grips.count >= 2 else { return }
        setSpeakers(left: grips[0].uid, right: grips[1].uid)
        // First launch: the pair appearing counts as both speakers connecting.
        bothSpeakersWerePresent = false
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
        refreshCurrentRoom()
        pairSettings = Self.loadPairSettings(store: store, left: left, right: right)
        // A new pair is not a speaker connecting, so it never auto-starts.
        bothSpeakersWerePresent = bothSelectedSpeakersPresent
        reloadQuadSettings()
        syncVolumeLink()
        applyPairSettingsToEngine()
        if wasActive {
            Task { await startRouting() }
        }
    }

    func setRear(left: String?, right: String?) {
        guard left != rearLeftUID || right != rearRightUID else { return }
        rearLeftUID = left
        rearRightUID = right
        let wasQuadActive = routingMode == .quad && engine.state.isActive
        if wasQuadActive { stopRouting() }
        store.lastRearLeftUID = left
        store.lastRearRightUID = right
        refreshCurrentRoom()
        reloadQuadSettings()
        syncVolumeLink()
        if wasQuadActive { Task { await startRouting() } }
    }

    /// Four distinct outputs are assigned (the Quad segment's enable rule).
    var isQuadAvailable: Bool {
        let uids = [leftUID, rightUID, rearLeftUID, rearRightUID].compactMap { $0 }
        return uids.count == 4 && Set(uids).count == 4
    }

    /// Quad is always selectable. Until four distinct outputs are assigned
    /// and present, routing stays stereo on the front pair.
    func setRoutingMode(_ mode: RoutingMode) {
        guard mode != routingMode else { return }
        let wasActive = engine.state.isActive
        if wasActive { stopRouting() }
        routingMode = mode
        store.routingMode = mode
        refreshCurrentRoom()
        syncVolumeLink()
        if wasActive { Task { await startRouting() } }
    }

    /// The four UIDs in position order when Quad is chosen and all four
    /// outputs are present; otherwise routing is stereo.
    var quadRouteUIDs: [String]? {
        guard Self.engineSupportsQuad, routingMode == .quad, isQuadAvailable else { return nil }
        let uids = [leftUID, rightUID, rearLeftUID, rearRightUID].compactMap { $0 }
        return uids.allSatisfy({ catalog.device(uid: $0) != nil }) ? uids : nil
    }

    func setRearTrim(_ trim: Float) {
        quadSettings.rearTrim = min(max(trim.isFinite ? trim : 1, 0), 1)
        engine.rearTrim = quadSettings.rearTrim
        guard isQuadAvailable else { return }
        store.setQuadSettings(quadSettings, uids: [leftUID, rightUID, rearLeftUID, rearRightUID].compactMap { $0 })
    }

    func setQuadRearEffects(_ change: (inout QuadSettings) -> Void) {
        change(&quadSettings)
        guard isQuadAvailable else { return }
        store.setQuadSettings(quadSettings, uids: [leftUID, rightUID, rearLeftUID, rearRightUID].compactMap { $0 })
        applyPairSettingsToEngine()
    }

    func setRearMode(_ mode: RearMode) {
        quadSettings.rearMode = mode.rawValue
        engine.rearMode = Int32(mode.rawValue)
        guard isQuadAvailable else { return }
        store.setQuadSettings(quadSettings, uids: [leftUID, rightUID, rearLeftUID, rearRightUID].compactMap { $0 })
    }

    private func reloadQuadSettings() {
        quadSettings = isQuadAvailable
            ? store.quadSettings(uids: [leftUID, rightUID, rearLeftUID, rearRightUID].compactMap { $0 })
            : QuadSettings()
    }

    func uid(at position: SpeakerPosition) -> String? {
        switch position {
        case .frontLeft: leftUID
        case .frontRight: rightUID
        case .rearLeft: rearLeftUID
        case .rearRight: rearRightUID
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
        let quad = quadRouteUIDs
        tones.stop()
        routingRefusal = nil
        applyInitialDelayIfUnset()
        if let left = leftUID, let right = rightUID, left != right,
           catalog.device(uid: left) != nil, catalog.device(uid: right) != nil {
            do throws(OutputRestorer.Failure) {
                try outputRestorer.prepareForRouting(
                    pair: Set(quad ?? [left, right]), playThroughUID: store.excludedAppsPlayThroughUID,
                    exclusionsActive: !engine.excludedProcesses.isEmpty)
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
        if let quad {
            await engine.start(quad: quad)
        } else {
            await engine.start(left: leftUID, right: rightUID)
        }
        if !engine.state.isActive {
            outputRestorer.restore(enabled: store.restorePreviousOutput)
        }
        syncWithEngine()
    }

    static let noOtherOutputMessage = "Connect another output to start"

    /// The only refusal is `noOtherOutputMessage`; it goes away as soon as
    /// an output outside the pair appears.
    private func clearRefusalIfResolved() {
        guard routingRefusal != nil,
              catalog.outputs.contains(where: { $0.uid != leftUID && $0.uid != rightUID }) else { return }
        routingRefusal = nil
    }

    func stopRouting(toBuiltInOutput: Bool = false) {
        stopClickTest()
        cancelTone()
        engine.stop()
        outputRestorer.restore(enabled: store.restorePreviousOutput, preferBuiltIn: toBuiltInOutput)
        syncWithEngine()
    }

    /// The engine stopped on its own (both speakers gone, or a rebuild
    /// failed): put the previous output back, as a user stop would.
    func engineEndedRouting() {
        stopClickTest()
        cancelTone()
        outputRestorer.restore(enabled: store.restorePreviousOutput)
        syncWithEngine()
    }

    func swapSides() {
        engine.swapSides.toggle()
    }

    // MARK: - Tuning and volume

    /// Master volume, 0...1 (SPEC 4a): hardware volume at the step at or above
    /// it, times a kernel gain for the remainder, so coarse Bluetooth steps
    /// still move smoothly. A speaker without a settable volume gets it as a kernel gain instead.
    func setMasterVolume(_ volume: Double) {
        let value = min(max(Float(volume), 0), 1)
        if volumeLink.volume != nil { volumeLink.setAtOrAbove(value) }
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
        let uids = routingMode == .quad && isQuadAvailable
            ? [leftUID, rightUID, rearLeftUID, rearRightUID] : [leftUID, rightUID]
        return uids.compactMap { uid in
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
                         balance: s.balance, masterVolume: s.masterVolume, effects: s.effects)
        guard s != pairSettings else { return }
        pairSettings = s
        mirrorMasterToVirtualOutput()
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
        applyQuadSettingsToEngine()
        let fronts = (pairSettings.effects.left, pairSettings.effects.effectiveRight)
        engine.setEffects(left: fronts.0, right: fronts.1)
        let rears = quadSettings.rearEffects(frontLeft: fronts.0, frontRight: fronts.1,
                                             linkSpeakers: pairSettings.effects.linkSpeakers)
        engine.setRearEffects(left: rears.left, right: rears.right)
    }

    /// Quad kernel controls: per-position gain and delay (the signed pair
    /// delay becomes two non-negative ones on the fronts), rear mode and trim.
    private func applyQuadSettingsToEngine() {
        let master = pairSettings.masterVolume
        engine.quadGains = [
            pairSettings.leftGain * kernelVolume(for: leftUID),
            pairSettings.rightGain * kernelVolume(for: rightUID),
            master * kernelVolume(for: rearLeftUID), master * kernelVolume(for: rearRightUID),
        ]
        let delay = pairSettings.delayMs
        engine.quadDelaysMs = [max(-delay, 0), max(delay, 0), 0, 0]
        engine.rearMode = Int32(quadSettings.rearMode)
        engine.rearTrim = quadSettings.rearTrim
    }

    func setEffects(_ effects: PairSettings.EffectsSettings) {
        updatePairSettings { $0.effects = effects }
    }

    func applyPreset(_ preset: PairSettings.Preset) {
        setEffects(preset.settings)
    }

    private func kernelVolume(for uid: String?) -> Float {
        let master = pairSettings.masterVolume
        if let uid, volumeLink.hasHardwareVolume(uid: uid) {
            // Hardware sits at or above the master; kernel gain makes up the rest.
            guard let hardware = volumeLink.volume, hardware > 0,
                  hardware - master > SpeakerVolumeLink.exactTolerance else { return 1 }
            return min(1, master / hardware)
        }
        return master
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
        guard engine.state.isRouting else {
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
        guard engine.state.isRouting, let first = steps.first else { return }
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

    /// Called whenever the engine state changes: meters poll only while routing.
    func syncWithEngine() {
        if engine.state.isRouting {
            if !hasRunEngine { hasRunEngine = true }
            if !meters.isRunning {
                meters.start { [weak self] in self?.readMeterPeaks() ?? (0, 0) }
            }
        } else if meters.isRunning {
            meters.stop()
        }
        if engine.state != .running && engine.clickTest { engine.clickTest = false }
        syncVirtualOutput()
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
