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
    /// Brings dropped Bluetooth speakers back (SpeakerReconnector).
    let reconnector: SpeakerReconnector
    /// Moves the default output off the pair and back (SPEC 4c).
    @ObservationIgnored let outputRestorer: OutputRestorer

    /// Why the last start request did not route, when the engine was never
    /// asked to start. Shown as the status line while idle.
    private(set) var routingRefusal: String?
    /// The user turned routing off this session. Blocks auto-start until a
    /// selected speaker disconnects and comes back (SPEC 6a).
    @ObservationIgnored var userTurnedRoutingOff = false
    /// Both selected speakers were present at the last catalog sync.
    @ObservationIgnored var speakersWerePresent = false
    /// Which speakers `speakersWerePresent` was about: a new pair, a changed
    /// surround set or a mode switch is not a speaker connecting.
    @ObservationIgnored var speakersPresenceKey = ""
    /// The pending auto-start, so tests can wait for it.
    @ObservationIgnored var autoStartTask: Task<Void, Never>?

    /// Selected speakers, by UID. `leftUID` is the Front Left device, which is
    /// always kernel position A. Change them with `setSpeakers(left:right:)`.
    private(set) var leftUID: String?
    private(set) var rightUID: String?
    /// Rear speakers of the old quad assign sheet. Kept for rooms and the
    /// quad migration; Surround uses `surroundSettings.speakers`.
    private(set) var rearLeftUID: String?
    private(set) var rearRightUID: String?
    /// The Stereo / Surround control. Surround routes once three speakers of
    /// the set are connected; until then routing stays stereo.
    private(set) var routingMode: RoutingMode = .stereo
    /// The surround set and its tuning (SPEC 13.1). Change it only through
    /// the methods in AppModel+Surround, which save it and reach the engine.
    var surroundSettings = SurroundSettings()

    // Demo (SPEC 14), polled at 30 Hz while it plays (AppModel+Surround).
    var demoPlaying = false
    /// Counts orbit resets, so the stage drawing turns back with the kernel.
    var orbitResetCount = 0
    var demoAzimuth: Float = 0
    var demoSection = 0
    @ObservationIgnored var demoPollTask: Task<Void, Never>?
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
    /// Drives the Bluetooth Speakers sheet.
    var showsBluetooth = false
    let bluetoothSpeakers: BluetoothSpeakersModel
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
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isStartingRouting = false
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
    /// Battery percent by speaker UID; unknown speakers are absent (AppModel+Battery).
    var batteryPercent: [String: Int] = [:]
    @ObservationIgnored let batteryReader: any BatteryReading
    @ObservationIgnored var batteryTask: Task<Void, Never>?
    /// Follows the Domine virtual output's volume and mute (AppModel+VirtualOutput).
    @ObservationIgnored var virtualOutput: VirtualOutputLink?
    /// Resolves excluded apps to process objects for the tap (SPEC 3b).
    @ObservationIgnored let exclusionResolver: ExclusionResolver
    /// Apps playing audio now, and their saved volumes by bundle ID (AppModel+AppAudio).
    let appAudio: AppAudioList
    var appVolumes: [String: Double]
    /// Pauses playback if Domine quits or crashes while routing (SPEC 16.11).
    @ObservationIgnored let pauseWatchdog: PauseWatchdog

    init(hal: any AudioHAL = CoreAudioHAL(), defaults: UserDefaults = .standard,
         services: SystemServices = .live,
         pauseWatchdog: PauseWatchdog = .live(),
         battery: any BatteryReading = IOBluetoothBatteryReader(),
         bluetooth: any BluetoothConnecting = IOBluetoothConnector(),
         radio: any BluetoothRadio = IOBluetoothRadio(),
         reconnectSleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        batteryReader = battery
        self.pauseWatchdog = pauseWatchdog
        let store = SettingsStore(defaults: defaults)
        self.hal = hal
        bluetoothSpeakers = BluetoothSpeakersModel(radio: radio, store: store)
        let catalog = DeviceCatalog(hal: hal)
        self.catalog = catalog
        volumeLink = SpeakerVolumeLink(hal: hal)
        reconnector = SpeakerReconnector(
            connector: bluetooth, isEnabled: { store.reconnectDroppedSpeakers }, sleep: reconnectSleep)
        outputRestorer = OutputRestorer(hal: hal, store: store, outputs: { catalog.outputs })
        engine = Engine(hal: hal)
        exclusionResolver = ExclusionResolver(hal: hal)
        appAudio = AppAudioList(hal: hal)
        appVolumes = store.appVolumes
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
        store.migrateQuadSets(rooms: rooms)
        surroundSettings = Self.loadSurroundSettings(store: store)
        currentRoomID = store.currentRoomID.flatMap { id in rooms.contains { $0.id == id } ? id : nil }
        pairSettings = Self.loadPairSettings(store: store, left: leftUID, right: rightUID)
        applyPairSettingsToEngine()
        volumeLink.onExternalChange = { [weak self] volume in self?.adoptHardwareVolume(volume) }
        engine.onRoutingEnded = { [weak self] in self?.engineEndedRouting() }
        engine.keepAlive = store.keepSpeakersAwake
        let engine = engine
        exclusionResolver.onChange = { [weak self] processes in
            self?.outputRestorer.setExclusionsActive(!processes.isEmpty)
            self?.syncVirtualOutput()
            await engine.setExcludedProcesses(processes)
            self?.applyAppVolumesToEngine()
        }
        appAudio.onRefresh = { [weak self] in self?.applyAppVolumesToEngine() }
    }

    /// Runs once per process. A reopened window must never repeat this: the
    /// stale-aggregate cleanup would destroy the running aggregate.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        StaleAggregateCleaner.clean(hal: hal)
        if engine.state.isActive {
            _ = exclusionResolver.start(exclusions: store.exclusions)
        } else {
            engine.excludedProcesses = exclusionResolver.start(exclusions: store.exclusions)
        }
        appAudio.start()
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
        startBatteryPolling()
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
        // First launch: the pair appearing counts as the speakers connecting.
        speakersWerePresent = false
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
        rememberBluetoothSpeakers([left, right])
        refreshCurrentRoom()
        pairSettings = Self.loadPairSettings(store: store, left: left, right: right)
        // A new pair is not a speaker connecting, so it never auto-starts.
        speakersWerePresent = allSpeakersPresent
        speakersPresenceKey = assignedSpeakersKey
        syncVolumeLink()
        applyPairSettingsToEngine()
        if wasActive {
            Task { await startRouting() }
        }
    }

    /// The old quad rear assignment, kept for rooms saved with rears.
    func setRear(left: String?, right: String?) {
        guard left != rearLeftUID || right != rearRightUID else { return }
        rearLeftUID = left
        rearRightUID = right
        store.lastRearLeftUID = left
        store.lastRearRightUID = right
        refreshCurrentRoom()
    }

    /// Switching to Surround the first time builds the set from the stereo
    /// pair (SPEC 13.6). A running engine restarts in the new mode.
    func setRoutingMode(_ mode: RoutingMode) {
        guard mode != routingMode else { return }
        let wasActive = engine.state.isActive
        if wasActive { stopRouting() }
        routingMode = mode
        store.routingMode = mode
        if mode == .surround { seedSurroundSetIfEmpty() }
        refreshCurrentRoom()
        syncVolumeLink()
        applyPairSettingsToEngine()
        if wasActive { Task { await startRouting() } }
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
        guard !engine.state.isActive, !isStartingRouting else { return }
        isStartingRouting = true
        defer { isStartingRouting = false }
        let surround = surroundRouteSpeakers
        tones.stop()
        routingRefusal = nil
        applyInitialDelayIfUnset()
        var routeUIDs: Set<String>?
        if let surround {
            routeUIDs = Set(surround.map(\.uid))
        } else if let left = leftUID, let right = rightUID, left != right,
                  catalog.device(uid: left) != nil, catalog.device(uid: right) != nil {
            routeUIDs = [left, right]
        }
        if let routeUIDs {
            do throws(OutputRestorer.Failure) {
                try outputRestorer.prepareForRouting(
                    pair: routeUIDs, playThroughUID: store.excludedAppsPlayThroughUID,
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
        if let surround {
            await engine.start(surround: surround)
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
        var uids: [String?] = [leftUID, rightUID]
        if let surround = surroundRouteSpeakers { uids = surround.map { $0.uid } }
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
        engine.crossfeed = pairSettings.effectiveCrossfeed
        engine.setEffects(left: pairSettings.effects.left, right: pairSettings.effects.effectiveRight)
        applySurroundSettingsToEngine()
    }

    /// Surround kernel controls (SPEC 13.4): per speaker trim times the
    /// master volume's kernel share, calibration offsets, effects, and the
    /// field controls. Distance compensation is added by the engine.
    func applySurroundSettingsToEngine() {
        let s = surroundSettings
        engine.surroundSpeakers = s.speakers
        var gains: [String: Float] = [:]
        var effects: [String: PairSettings.SideEffects] = [:]
        for uid in s.uids {
            gains[uid] = s.trim(for: uid) * kernelVolume(for: uid)
            effects[uid] = s.resolvedEffects(for: uid)
        }
        engine.surroundGains = gains
        engine.surroundDelaysMs = s.offsetsMs
        engine.surroundTimingMeasured = s.timingMeasured
        engine.setSurroundEffects(effects)
        engine.surroundWidth = s.width
        engine.surroundLevel = s.surroundLevel
        engine.surroundMono = s.mono
        engine.orbitRate = s.orbitRate
        engine.rotation = s.rotation
        engine.spatialAmount = s.spatialAmount
        engine.spatialRoomMs = s.spatialRoomMs
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
        engine.surroundTestTone = nil
    }

    // MARK: - Reacting to the catalog and engine

    /// Called whenever the output list changes.
    func syncWithCatalog() {
        for device in catalog.outputs { knownNames[device.uid] = device.name }
        clearRefusalIfResolved()
        chooseDefaultSpeakers()
        syncSettingsWithCatalog()
        syncVolumeLink()
        refreshBatteryLevels()
        autoStartIfSpeakersConnected()
        syncReconnector()
        if showsBluetooth { bluetoothSpeakers.refresh() }
    }

    /// Assigned speakers that are not in the catalog right now.
    func syncReconnector() {
        let assigned: [String?] = routingMode == .surround
            ? surroundSpeakers.map(\.uid) : [leftUID, rightUID]
        reconnector.update(missing: Set(assigned.compactMap { $0 }.filter { catalog.device(uid: $0) == nil }))
    }

    /// Every speaker the current mode routes to: the pair in Stereo, the
    /// whole set in Surround.
    var assignedSpeakerUIDs: [String] {
        routingMode == .surround
            ? surroundSpeakers.map(\.uid)
            : [leftUID, rightUID].compactMap { $0 }
    }

    private var assignedSpeakersKey: String {
        "\(routingMode):" + assignedSpeakerUIDs.sorted().joined(separator: ",")
    }

    /// All of the current mode's speakers are connected: both of the pair,
    /// or every speaker of the surround set (at least the surround minimum).
    var allSpeakersPresent: Bool {
        guard routingMode == .surround else { return bothSelectedSpeakersPresent }
        let uids = Set(assignedSpeakerUIDs)
        return uids.count >= Self.surroundMinimumSpeakers
            && uids.allSatisfy { catalog.device(uid: $0) != nil }
    }

    /// "Start routing when speakers connect" (SPEC 6a): starts when the
    /// last of the current mode's speakers becomes present while routing is
    /// off. After the user turned routing off, it waits until a speaker
    /// disconnects and returns.
    func autoStartIfSpeakersConnected() {
        let present = allSpeakersPresent
        let key = assignedSpeakersKey
        let connected = present && !speakersWerePresent && key == speakersPresenceKey
        speakersWerePresent = present
        speakersPresenceKey = key
        if !present, !assignedSpeakerUIDs.isEmpty { userTurnedRoutingOff = false }
        guard connected, store.startWhenBothConnect, !userTurnedRoutingOff, !engine.state.isActive else { return }
        Self.log.info("Speakers connected; starting routing")
        autoStartTask = Task { [weak self] in await self?.startRouting() }
    }

    /// Called whenever the engine state changes: meters poll only while routing.
    func syncWithEngine() {
        if engine.state.isRouting {
            if !hasRunEngine { hasRunEngine = true }
            if !meters.isRunning {
                meters.start(
                    reader: { [weak self] in self?.readMeterPeaks() ?? (0, 0) },
                    surroundReader: { [weak self] in self?.readSurroundPeaks() ?? [:] })
            }
        } else if meters.isRunning {
            meters.stop()
        }
        if !engine.state.isRouting, demoPlaying { syncDemoStatus() }
        if engine.state != .running && engine.clickTest { engine.clickTest = false }
        syncVirtualOutput()
        syncPauseWatchdog()
    }

    /// One watchdog while routing with "Pause playback if Domine quits while playing" on (SPEC 16.11).
    func syncPauseWatchdog() {
        pauseWatchdog.update(routing: engine.state.isRouting, enabled: store.pauseOnExit)
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
