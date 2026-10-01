import AppKit
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
    @ObservationIgnored let store: SettingsStore

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
    var showsTuning = false
    /// Read from the HAL each time the tuning sheet opens.
    var reportedLatencyText: String?

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

    init(hal: any AudioHAL = CoreAudioHAL(), defaults: UserDefaults = .standard,
         services: SystemServices = .live) {
        let store = SettingsStore(defaults: defaults)
        catalog = DeviceCatalog(hal: hal)
        engine = Engine(hal: hal)
        captureAccess = AudioCapturePermission(hal: hal, store: store)
        self.store = store
        self.services = services
        showsWelcome = !store.hasCompletedWelcome
        generalSettings = Self.makeGeneralSettings(store: store, services: services)
        exclusionsSettings = Self.makeExclusionsSettings(store: store, services: services)
        leftUID = store.lastLeftUID
        rightUID = store.lastRightUID
        pairSettings = Self.loadPairSettings(store: store, left: leftUID, right: rightUID)
        applyPairSettingsToEngine()
    }

    func start() {
        catalog.start()
        syncWithCatalog()
        syncWithEngine()
        guard terminationObserver == nil else { return }
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
        store.lastLeftUID = left
        store.lastRightUID = right
        pairSettings = Self.loadPairSettings(store: store, left: left, right: right)
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

    func setRouting(_ on: Bool) {
        if on {
            Task { await startRouting() }
        } else {
            stopRouting()
        }
    }

    func startRouting() async {
        applyPairSettingsToEngine()
        await engine.start(left: leftUID, right: rightUID)
        syncWithEngine()
    }

    func stopRouting() {
        cancelTone()
        engine.stop()
        syncWithEngine()
    }

    func swapSides() {
        engine.swapSides.toggle()
    }

    // MARK: - Tuning and volume

    /// Master volume, 0...1. For now a kernel gain on both positions; hardware
    /// volume linking (SPEC section 4a) replaces what this applies, not its callers.
    func setMasterVolume(_ volume: Double) {
        updatePairSettings { $0.masterVolume = Float(volume) }
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

    private func applyPairSettingsToEngine() {
        engine.leftGain = pairSettings.leftGain * pairSettings.masterVolume
        engine.rightGain = pairSettings.rightGain * pairSettings.masterVolume
        engine.delayMs = pairSettings.delayMs
    }

    private static func loadPairSettings(store: SettingsStore, left: String?, right: String?) -> PairSettings {
        guard let left, let right, left != right else { return PairSettings() }
        return store.pairSettings(leftUID: left, rightUID: right)
    }

    // MARK: - Test tones

    /// Starts the tone on that side, or stops it if it is already playing.
    func toggleTestTone(_ side: StereoSide) {
        let tone: TestTone = side == .left ? .left : .right
        let playing = engine.testTone == tone
        cancelTone()
        engine.testTone = playing ? .off : tone
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
        chooseDefaultSpeakers()
        syncSettingsWithCatalog()
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
