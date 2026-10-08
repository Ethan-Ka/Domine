import Foundation

/// The Presets menu (SPEC 13.1). A preset assigns azimuths only.
enum SurroundPreset: String, CaseIterable, Sendable {
    case frontBack, quad, five, seven, ring

    var title: String {
        switch self {
        case .frontBack: "Front and Back"
        case .quad: "Quad"
        case .five: "5 speaker"
        case .seven: "7 speaker"
        case .ring: "Ring"
        }
    }

    /// Front and Back needs 2; Quad, 5 and 7 need exactly that many speakers;
    /// Ring takes any number.
    func isEnabled(speakerCount: Int) -> Bool {
        switch self {
        case .frontBack: speakerCount == 2
        case .quad: speakerCount == 4
        case .five: speakerCount == 5
        case .seven: speakerCount == 7
        case .ring: speakerCount > 0
        }
    }

    /// The preset's azimuths for `count` speakers, or nil when it does not apply.
    func azimuths(count: Int) -> [Float]? {
        guard isEnabled(speakerCount: count) else { return nil }
        switch self {
        case .frontBack: return [0, 180]
        case .quad: return [-30, 30, -110, 110]
        case .five: return [-30, 0, 30, -110, 110]
        case .seven: return [-30, 0, 30, -90, 90, -150, 150]
        case .ring:
            // Evenly spaced, -180 + 360 (i + 0.5) / N: 4 gives -135, -45, 45, 135.
            return (0..<count).map { -180 + 360 * (Float($0) + 0.5) / Float(count) }
        }
    }
}

/// Surround mode (SPEC 13) and the demo (SPEC 14). Every change to the set
/// or its tuning is saved under the set's key and reaches the engine at once.
extension AppModel {
    static let demoPollInterval: Duration = .nanoseconds(1_000_000_000 / 30)
    /// More Bluetooth speakers than this in the set shows the bandwidth warning.
    static let bluetoothSpeakerLimit = 4

    var surroundSpeakers: [SurroundSpeaker] { surroundSettings.speakers }

    /// Outputs that can be in a surround set: connected, with at least two
    /// output channels, since the kernel writes offset and offset + 1 (SPEC 13.2).
    var surroundEligibleOutputs: [OutputDevice] {
        catalog.outputs.filter { $0.outputChannels >= 2 }
    }

    /// Fewest connected speakers Surround routes (SPEC 13.6). Two can sit
    /// front and back: the Surround slider sends ambience to the rear one.
    static let surroundMinimumSpeakers = 2

    /// Surround can be chosen: at least two distinct eligible outputs are
    /// connected (SPEC 13.6, the toolbar's enable rule).
    var isSurroundAvailable: Bool {
        Set(surroundEligibleOutputs.map(\.uid)).count >= Self.surroundMinimumSpeakers
    }

    /// Speakers of the set that are connected and eligible.
    var connectedSurroundSpeakers: [SurroundSpeaker] {
        surroundSpeakers.filter { speaker in
            catalog.device(uid: speaker.uid).map { $0.outputChannels >= 2 } ?? false
        }
    }

    /// The set to route when Surround is chosen and two of its speakers
    /// are connected; otherwise routing is stereo on the pair. Speakers that
    /// are not connected stay in (they rejoin when they return); a connected
    /// output with one channel is left out.
    var surroundRouteSpeakers: [SurroundSpeaker]? {
        guard routingMode == .surround, connectedSurroundSpeakers.count >= Self.surroundMinimumSpeakers else { return nil }
        return surroundSpeakers.filter { speaker in
            catalog.device(uid: speaker.uid).map { $0.outputChannels >= 2 } ?? true
        }
    }

    /// Meter level for a surround card, 0...1.
    func surroundLevel(uid: String) -> Float {
        meters.surroundLevels[uid] ?? 0
    }

    /// Linear peaks per routed surround speaker, for the meters.
    func readSurroundPeaks() -> [String: Float] {
        guard let route = engine.surroundRoute else { return [:] }
        let peaks = engine.surroundPeaks()
        guard peaks.count == route.count else { return [:] }
        return Dictionary(zip(route, peaks), uniquingKeysWith: { first, _ in first })
    }

    /// More than four connected Bluetooth speakers in the set (SPEC 13.6).
    var showsBluetoothBandwidthWarning: Bool {
        surroundSpeakers.filter { catalog.device(uid: $0.uid)?.isBluetooth == true }.count > Self.bluetoothSpeakerLimit
    }

    // MARK: - The set

    /// Appends a speaker at the default azimuth for its index. No duplicates,
    /// at most 16, and never a connected output with one channel.
    func addSurroundSpeaker(uid: String) {
        guard !surroundSpeakers.contains(where: { $0.uid == uid }),
              surroundSpeakers.count < SurroundSpeaker.maxCount else { return }
        if let device = catalog.device(uid: uid), device.outputChannels < 2 { return }
        changeSurroundSet(surroundSettings.uids + [uid])
    }

    func removeSurroundSpeaker(uid: String) {
        guard surroundSpeakers.contains(where: { $0.uid == uid }) else { return }
        changeSurroundSet(surroundSettings.uids.filter { $0 != uid })
    }

    /// A new list of speakers: the record carries over (SPEC 13.1) and is
    /// saved under the new key. Surround routing restarts for the new
    /// aggregate, since a running one is never changed.
    func changeSurroundSet(_ uids: [String]) {
        let restart = routingMode == .surround && engine.state.isActive
        if restart { stopRouting() }
        surroundSettings = surroundSettings.carried(to: uids)
        saveSurroundSettings()
        refreshCurrentRoom()
        syncVolumeLink()
        applySurroundSettingsToEngine()
        if restart { Task { await startRouting() } }
    }

    /// Loads a saved set (a room's): its stored record, else the current
    /// record carried over to it.
    func selectSurroundSet(_ uids: [String]) {
        guard uids != surroundSettings.uids else { return }
        let restart = routingMode == .surround && engine.state.isActive
        if restart { stopRouting() }
        surroundSettings = store.surroundSettings(uids: uids) ?? surroundSettings.carried(to: uids)
        saveSurroundSettings()
        syncVolumeLink()
        applySurroundSettingsToEngine()
        if restart { Task { await startRouting() } }
    }

    /// The first switch to Surround (SPEC 13.6): the stereo pair at -30 and
    /// +30 (swap applied: the speaker playing left is first). Nothing else
    /// joins on its own; the Mac's speakers or AirPods would be an odd pick,
    /// so more speakers come from "Add Speaker…".
    func seedSurroundSetIfEmpty() {
        guard surroundSpeakers.isEmpty else { return }
        var uids: [String] = []
        let pair = engine.swapSides ? [rightUID, leftUID] : [leftUID, rightUID]
        for uid in pair.compactMap({ $0 }) where !uids.contains(uid) { uids.append(uid) }
        guard !uids.isEmpty else { return }
        surroundSettings = store.surroundSettings(uids: uids) ?? SurroundSettings(uids: uids)
        saveSurroundSettings()
        applySurroundSettingsToEngine()
    }

    static func loadSurroundSettings(store: SettingsStore) -> SurroundSettings {
        guard let uids = store.lastSurroundUIDs, !uids.isEmpty else { return SurroundSettings() }
        return store.surroundSettings(uids: uids) ?? SurroundSettings(uids: uids)
    }

    func saveSurroundSettings() {
        guard !surroundSettings.speakers.isEmpty else { return }
        store.setSurroundSettings(surroundSettings)
        store.lastSurroundUIDs = surroundSettings.uids
        rememberBluetoothSpeakers(surroundSettings.uids)
    }

    /// Edits the record, sanitizes and saves it, and pushes it to the engine.
    func updateSurroundSettings(_ change: (inout SurroundSettings) -> Void) {
        var s = surroundSettings
        change(&s)
        s.sanitize()
        guard s != surroundSettings else { return }
        surroundSettings = s
        saveSurroundSettings()
        applySurroundSettingsToEngine()
    }

    // MARK: - Positions

    /// Wraps the azimuth to (-180, 180] and clamps the distance to
    /// 0.5...10 m. The engine follows live, without a rebuild.
    func moveSurroundSpeaker(uid: String, azimuth: Float, distance: Float) {
        guard let index = surroundSpeakers.firstIndex(where: { $0.uid == uid }) else { return }
        updateSurroundSettings { s in
            s.speakers[index].azimuth = SurroundSpeaker.wrap(azimuth)
            s.speakers[index].distance = SurroundSettings.clamp(
                distance, SurroundSpeaker.distanceRange, fallback: s.speakers[index].distance)
        }
    }

    /// Maps the preset's azimuths onto the speakers keeping their clockwise
    /// order: the current azimuths and the preset's are both sorted, and the
    /// nth lowest speaker takes the nth lowest preset azimuth (SPEC 13.1).
    /// Does nothing when the preset does not fit the number of speakers.
    func applySurroundPreset(_ preset: SurroundPreset) {
        let speakers = surroundSpeakers
        guard let targets = preset.azimuths(count: speakers.count) else { return }
        let order = speakers.indices.sorted { a, b in
            speakers[a].azimuth != speakers[b].azimuth ? speakers[a].azimuth < speakers[b].azimuth : a < b
        }
        let sorted = targets.sorted()
        updateSurroundSettings { s in
            for (rank, index) in order.enumerated() { s.speakers[index].azimuth = sorted[rank] }
        }
    }

    // MARK: - Field controls

    /// Degrees, clamped to 10...90.
    func setSurroundWidth(_ degrees: Float) {
        updateSurroundSettings { $0.width = degrees }
    }

    /// Ambience level, clamped to 0...1.
    func setSurroundLevel(_ level: Float) {
        updateSurroundSettings { $0.surroundLevel = level }
    }

    /// Degrees per second, clamped to +-720. 0 stops and resets the orbit.
    func setOrbitRate(_ degreesPerSecond: Float) {
        updateSurroundSettings { $0.orbitRate = degreesPerSecond }
    }

    /// Degrees, wrapped to (-180, 180].
    func setSurroundRotation(_ degrees: Float) {
        updateSurroundSettings { $0.rotation = degrees }
    }

    /// Returns the orbit phase to 0.
    func resetSurroundOrbit() {
        engine.resetOrbit()
        orbitResetCount += 1
    }

    /// Ambience amount 0...1 and room size 5...30 ms.
    func setSpatial(amount: Float? = nil, roomMs: Float? = nil) {
        updateSurroundSettings { s in
            if let amount { s.spatialAmount = amount }
            if let roomMs { s.spatialRoomMs = roomMs }
        }
    }

    // MARK: - Per speaker (Sync & Balance in Surround)

    /// Trim gain 0...1.
    func setSurroundTrim(uid: String, _ trim: Float) {
        guard surroundSpeakers.contains(where: { $0.uid == uid }) else { return }
        updateSurroundSettings { $0.trims[uid] = trim }
    }

    /// Calibration offset in ms, 0...300 (Bluetooth latency correction).
    func setSurroundOffset(uid: String, ms: Float) {
        guard surroundSpeakers.contains(where: { $0.uid == uid }) else { return }
        updateSurroundSettings { $0.offsetsMs[uid] = ms }
    }

    /// The effects the speaker plays with (the first speaker's while linked).
    func surroundEffects(uid: String) -> PairSettings.SideEffects {
        surroundSettings.resolvedEffects(for: uid)
    }

    /// Sets a speaker's effects; while linked this edits the shared ones
    /// (the first speaker's).
    func setSurroundEffects(uid: String, _ effects: PairSettings.SideEffects) {
        guard let first = surroundSpeakers.first?.uid,
              surroundSpeakers.contains(where: { $0.uid == uid }) else { return }
        updateSurroundSettings { s in s.effects[s.linkEffects ? first : uid] = effects }
    }

    /// Mono in the Sound sheet: L and R summed before panning.
    func setSurroundMono(_ on: Bool) {
        updateSurroundSettings { $0.mono = on }
    }

    func setSurroundEffectsLinked(_ linked: Bool) {
        updateSurroundSettings { $0.linkEffects = linked }
    }

    // MARK: - Test tone

    /// Pause between speakers in "Test Speakers", so each chime stands alone.
    static let speakerTestGap: Duration = .milliseconds(250)

    /// The chime on one surround speaker: through the engine while it routes
    /// that speaker, otherwise directly on the device.
    func playTestTone(surroundUID uid: String) {
        tones.stop()
        cancelTone()
        guard startSurroundTone(uid: uid) else { return }
        toneTask = Task { [weak self] in
            try? await Task.sleep(for: DeviceTonePlayer.duration)
            if Task.isCancelled { return }
            self?.engine.surroundTestTone = nil
        }
    }

    /// "Test Speakers": the chime on every connected speaker of the set, one
    /// at a time in list order. Each card lights up while its chime plays.
    func testSurroundSpeakers() {
        tones.stop()
        cancelTone()
        let uids = connectedSurroundSpeakers.map(\.uid)
        guard !uids.isEmpty else { return }
        toneTask = Task { [weak self] in
            for uid in uids {
                guard let self, !Task.isCancelled else { return }
                guard self.startSurroundTone(uid: uid) else { continue }
                try? await Task.sleep(for: DeviceTonePlayer.duration)
                if Task.isCancelled { return }
                self.engine.surroundTestTone = nil
                try? await Task.sleep(for: Self.speakerTestGap)
            }
        }
    }

    /// Starts the chime on one speaker and returns whether it sounds.
    private func startSurroundTone(uid: String) -> Bool {
        if engine.state.isRouting, engine.surroundRoute?.contains(uid) == true {
            engine.surroundTestTone = uid
            return true
        }
        guard catalog.device(uid: uid) != nil else { return false }
        tones.play(uid: uid)
        return true
    }

    /// The surround speaker whose test tone is sounding, if any.
    var surroundTestToneUID: String? {
        if let uid = engine.surroundTestTone { return uid }
        guard !engine.state.isRouting, let playing = tones.playingUID,
              surroundSpeakers.contains(where: { $0.uid == playing }) else { return nil }
        return playing
    }

    // MARK: - Demo (SPEC 14)

    /// Routing with at least two speakers present.
    var canPlayDemo: Bool {
        switch engine.state {
        case .running: return true
        case .degraded(.quadFallback(let missing)):
            return (engine.surroundRoute?.count ?? 0) - missing.count >= 2
        default: return false
        }
    }

    func startDemo() {
        guard canPlayDemo else { return }
        demoPlaying = true
        Task { [weak self] in
            guard let self else { return }
            await self.engine.setDemo(true)
            self.syncDemoStatus()
            self.pollDemoStatus()
        }
    }

    func stopDemo() {
        Task { [weak self] in
            guard let self else { return }
            await self.engine.setDemo(false)
            self.syncDemoStatus()
        }
    }

    /// "Calibration", "Left and right", "Sweep", "Orbit", "Swell", "Silence",
    /// "Impact"; nil when idle or finished.
    var demoSectionTitle: String? {
        Self.demoSectionTitle(demoSection)
    }

    /// DOMINE_DEMO_SECTION_* values (DomineDemo.h). In play order: 1, 2, 7, 3,
    /// 4, 8, 5. 0 is idle and 6 finished.
    static func demoSectionTitle(_ section: Int) -> String? {
        switch section {
        case 1: "Calibration"
        case 2: "Left and right"
        case 7: "Sweep"
        case 3: "Orbit"
        case 4: "Swell"
        case 8: "Silence"
        case 5: "Impact"
        default: nil
        }
    }

    /// Polls the demo at 30 Hz until it ends.
    func pollDemoStatus() {
        demoPollTask?.cancel()
        demoPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.demoPollInterval)
                guard !Task.isCancelled, let self else { return }
                self.syncDemoStatus()
                if !self.demoPlaying { return }
            }
        }
    }

    /// Copies the engine's demo state into the observable values.
    func syncDemoStatus() {
        let playing = engine.demoRequested
        let status = engine.demoStatus()
        let azimuth = playing ? status.azimuth : 0
        let section = playing ? Int(status.section) : 0
        if demoPlaying != playing { demoPlaying = playing }
        if demoAzimuth != azimuth { demoAzimuth = azimuth }
        if demoSection != section { demoSection = section }
        if !playing {
            demoPollTask?.cancel()
            demoPollTask = nil
        }
    }
}
