import CoreAudio
import os

/// Keeps the selected speakers' hardware volumes linked (SPEC section 4a).
///
/// Master volume is the speakers' own `kAudioDevicePropertyVolumeScalar`.
/// On attach the link reads every speaker and, if they differ, sets all of
/// them to the lowest so nothing jumps up. Afterwards a change on one
/// speaker that Domine did not make (the + button on a Grip) is copied to
/// the others and reported through `onExternalChange`. Domine's own writes
/// notify the listeners too, so each write opens a short suppression window
/// on the device it wrote.
///
/// Each speaker can carry a volume offset in dB (mixed speaker types, where
/// one plays quieter than the others at the same setting). The master is
/// then the level of a speaker with offset 0; a speaker with an offset is
/// set to the master moved by its offset on its own dB curve
/// (`kAudioDevicePropertyVolumeScalarToDecibels`), or on an approximate
/// curve when the device has none. Readings are compared and mirrored as
/// master-equivalent levels (hardware minus offset).
///
/// A speaker without a settable volume is left out; the caller applies the
/// master volume (and a negative offset) to it as a kernel gain instead.
@MainActor
final class SpeakerVolumeLink {
    static let suppression: Duration = .milliseconds(400)
    /// Smaller differences count as equal (Bluetooth volume is quantized).
    static let tolerance: Float = 0.01
    /// Hardware and master closer than this are the same level (no kernel gain).
    static let exactTolerance: Float = 0.0001
    /// Allowed per-speaker offsets, dB.
    nonisolated static let offsetRange: ClosedRange<Float> = -12...12
    /// Without the device's own dB curve, the scalar is taken as linear in
    /// dB over this span (scalar 1 is the top).
    nonisolated static let approximateSpanDb: Float = 48

    private struct Speaker {
        let uid: String
        let id: AudioObjectID
        let elements: [AudioObjectPropertyElement]
        var listeners: [HALListenerToken] = []
        var suppressedUntil: ContinuousClock.Instant?
    }

    private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "Volume")

    private let hal: any AudioHAL
    private let now: @MainActor () -> ContinuousClock.Instant
    private var speakers: [Speaker] = []
    /// The linked volume, as last written or mirrored.
    private(set) var volume: Float?
    /// Volume offset per speaker UID in dB; missing is 0. Kept across attaches.
    private(set) var offsets: [String: Float] = [:]
    /// Speakers at full hardware volume that still cannot reach their offset.
    private(set) var atMaximum: Set<String> = []

    /// Called with the new volume after a speaker changed on its own and the
    /// change was copied to the others.
    var onExternalChange: (@MainActor (Float) -> Void)?

    init(hal: any AudioHAL, now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.hal = hal
        self.now = now
    }

    /// UID to device ID of every attached speaker, including ones without a
    /// settable volume. Used to tell whether a re-attach is needed.
    private(set) var attachedDevices: [String: AudioObjectID] = [:]

    /// True when the speaker is attached and Domine can set its volume.
    func hasHardwareVolume(uid: String) -> Bool {
        speakers.contains { $0.uid == uid }
    }

    /// True when the speaker is at full volume and its offset is not fully
    /// honoured, so the UI can say so.
    func isAtMaximum(uid: String) -> Bool {
        atMaximum.contains(uid)
    }

    /// Sets every speaker's offset and moves the hardware to match.
    func setOffsets(_ new: [String: Float]) {
        let cleaned = new.compactMapValues { value -> Float? in
            guard value.isFinite, value != 0 else { return nil }
            return min(max(value, Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        }
        guard cleaned != offsets else { return }
        offsets = cleaned
        if let volume { write(volume) }
    }

    /// Reads the speakers, links them to the lowest volume, and starts
    /// listening. Returns the linked volume, or nil when no speaker has a
    /// settable volume. `devices` maps each present speaker's UID to its ID.
    @discardableResult
    func attach(_ devices: [(uid: String, id: AudioObjectID)]) -> Float? {
        detach()
        attachedDevices = Dictionary(devices.map { ($0.uid, $0.id) }, uniquingKeysWith: { first, _ in first })
        for device in devices {
            do {
                let elements = try hal.volumeElements(of: device.id)
                guard !elements.isEmpty else {
                    Self.log.info("\(device.uid, privacy: .public) has no settable volume; master volume uses kernel gain for it")
                    continue
                }
                speakers.append(Speaker(uid: device.uid, id: device.id, elements: elements))
            } catch {
                Self.log.error("Could not read volume elements of \(device.uid, privacy: .public): \(error.description, privacy: .public); using kernel gain for it")
            }
        }
        listen()
        return relink()
    }

    /// Reads every attached speaker again and sets them all to the lowest.
    /// Returns the linked volume, or nil without hardware volume.
    @discardableResult
    func relink() -> Float? {
        let readings = speakers.compactMap { speaker in
            read(speaker).map { (speaker: speaker, hardware: $0, master: masterEquivalent(of: $0, speaker)) }
        }
        guard let lowest = readings.map(\.master).min() else {
            volume = nil
            return nil
        }
        let differs = readings.contains { abs($0.hardware - hardware(forMaster: lowest, $0.speaker).value) > Self.tolerance }
        if differs {
            let text = readings.map { "\($0.speaker.uid) \($0.hardware)" }.joined(separator: ", ")
            Self.log.info("Speaker volumes differ (\(text, privacy: .public)); linking them to \(lowest)")
            write(lowest)
        } else {
            updateAtMaximum(lowest)
        }
        volume = lowest
        return lowest
    }

    /// Sets every attached speaker to `volume`.
    func set(_ volume: Float) {
        let clamped = min(max(volume, 0), 1)
        write(clamped)
        self.volume = clamped
    }

    /// Hardware step size learned from read-backs (Bluetooth volume is coarse).
    private(set) var step: Float?

    /// Sets the speakers to the nearest hardware step at or above `volume`
    /// and returns the volume they actually took, so the caller can make up
    /// the difference with kernel gain. Learns the step size from read-backs.
    @discardableResult
    func setAtOrAbove(_ volume: Float) -> Float? {
        let target = min(max(volume, 0), 1)
        let slack: Float = 0.0001
        if let current = self.volume, let step,
           current >= target - slack, current - target < step - slack {
            return current
        }
        var attempt = target
        if let step { attempt = min(1, (target / step - 0.001).rounded(.up) * step) }
        var last: Float?
        for _ in 0..<20 {
            write(attempt)
            // The speaker with the lowest offset is the least likely to be clamped.
            guard let speaker = speakers.min(by: { offset($0.uid) < offset($1.uid) }),
                  let reading = read(speaker) else { return self.volume }
            let got = masterEquivalent(of: reading, speaker)
            if let last, got != last { step = min(step ?? .infinity, abs(got - last)) }
            last = got
            self.volume = got
            if got >= target - slack || attempt >= 1 { return got }
            attempt = min(1, attempt + 1.0 / 64)
        }
        return self.volume
    }

    func detach() {
        for index in speakers.indices {
            speakers[index].listeners.forEach { $0.cancel() }
        }
        speakers = []
        attachedDevices = [:]
        atMaximum = []
        volume = nil
    }

    // MARK: Private

    private func listen() {
        for index in speakers.indices {
            let speaker = speakers[index]
            for element in speaker.elements {
                do {
                    let token = try hal.addListener(.volume(speaker.id, element: element)) { [weak self] in
                        self?.volumeChanged(uid: speaker.uid)
                    }
                    speakers[index].listeners.append(token)
                } catch {
                    Self.log.error("Could not listen to volume of \(speaker.uid, privacy: .public): \(error.description, privacy: .public)")
                }
            }
        }
    }

    private func volumeChanged(uid: String) {
        guard let speaker = speakers.first(where: { $0.uid == uid }) else { return }
        if let until = speaker.suppressedUntil, now() < until { return }
        guard let reading = read(speaker) else { return }
        if let volume, abs(reading - hardware(forMaster: volume, speaker).value) <= Self.tolerance { return }
        let value = masterEquivalent(of: reading, speaker)
        Self.log.info("\(uid, privacy: .public) changed to \(reading) outside Domine; master is now \(value)")
        write(value, except: uid)
        volume = value
        onExternalChange?(value)
    }

    // MARK: Offsets

    private func offset(_ uid: String) -> Float { offsets[uid] ?? 0 }

    /// The hardware scalar that plays `master` with the speaker's offset,
    /// and whether full scale is not enough for it.
    private func hardware(forMaster master: Float, _ speaker: Speaker) -> (value: Float, atMaximum: Bool) {
        let offset = offset(speaker.uid)
        guard offset != 0, master > 0 else { return (master, false) }
        if let curve = curve(speaker), let db = try? curve.toDb(master) {
            let target = db + offset
            if target >= curve.maxDb { return (1, target > curve.maxDb + 0.01) }
            if target <= curve.minDb { return (0, false) }
            if let scalar = try? curve.toScalar(target) { return (min(max(scalar, 0), 1), false) }
        }
        let scalar = master + offset / Self.approximateSpanDb
        return (min(max(scalar, 0), 1), scalar > 1 + Self.exactTolerance)
    }

    /// The master level a hardware reading stands for: the reading minus
    /// the speaker's offset.
    private func masterEquivalent(of hardware: Float, _ speaker: Speaker) -> Float {
        let offset = offset(speaker.uid)
        guard offset != 0, hardware > 0 else { return hardware }
        if let curve = curve(speaker), let db = try? curve.toDb(hardware) {
            let target = db - offset
            if target <= curve.minDb { return 0 }
            if target >= curve.maxDb { return 1 }
            if let scalar = try? curve.toScalar(target) { return min(max(scalar, 0), 1) }
        }
        return min(max(hardware - offset / Self.approximateSpanDb, 0), 1)
    }

    private struct Curve {
        let minDb: Float
        let maxDb: Float
        let toDb: (Float) throws(HALError) -> Float
        let toScalar: (Float) throws(HALError) -> Float
    }

    /// The device's own dB curve on its first element, or nil without one.
    private func curve(_ speaker: Speaker) -> Curve? {
        guard let element = speaker.elements.first else { return nil }
        let hal = self.hal
        let id = speaker.id
        let toDb: (Float) throws(HALError) -> Float = { scalar throws(HALError) in
            try hal.volumeDecibels(fromScalar: scalar, of: id, element: element)
        }
        let toScalar: (Float) throws(HALError) -> Float = { db throws(HALError) in
            try hal.volumeScalar(fromDecibels: db, of: id, element: element)
        }
        guard let minDb = try? toDb(0), let maxDb = try? toDb(1), maxDb > minDb else { return nil }
        return Curve(minDb: minDb, maxDb: maxDb, toDb: toDb, toScalar: toScalar)
    }

    private func updateAtMaximum(_ master: Float) {
        atMaximum = Set(speakers.filter { hardware(forMaster: master, $0).atMaximum }.map(\.uid))
    }

    /// Average over the speaker's elements, so a per-channel device reads as one value.
    private func read(_ speaker: Speaker) -> Float? {
        do {
            var total: Float = 0
            for element in speaker.elements {
                total += try hal.volume(of: speaker.id, element: element)
            }
            return total / Float(speaker.elements.count)
        } catch {
            Self.log.error("Could not read volume of \(speaker.uid, privacy: .public): \(error.description, privacy: .public)")
            return nil
        }
    }

    /// Sets every speaker (but `skipped`) to the master `value` moved by its offset.
    private func write(_ value: Float, except skipped: String? = nil) {
        updateAtMaximum(value)
        for index in speakers.indices where speakers[index].uid != skipped {
            let target = hardware(forMaster: value, speakers[index]).value
            // Set before writing: the HAL may notify while the write is in progress.
            speakers[index].suppressedUntil = now().advanced(by: Self.suppression)
            let speaker = speakers[index]
            for element in speaker.elements {
                do {
                    try hal.setVolume(target, of: speaker.id, element: element)
                } catch {
                    Self.log.error("Could not set volume of \(speaker.uid, privacy: .public): \(error.description, privacy: .public)")
                }
            }
        }
    }
}
