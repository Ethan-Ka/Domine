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
/// A speaker without a settable volume is left out; the caller applies the
/// master volume to it as a kernel gain instead.
@MainActor
final class SpeakerVolumeLink {
    static let suppression: Duration = .milliseconds(400)
    /// Smaller differences count as equal (Bluetooth volume is quantized).
    static let tolerance: Float = 0.01
    /// Hardware and master closer than this are the same level (no kernel gain).
    static let exactTolerance: Float = 0.0001

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
        let readings = speakers.compactMap { speaker in read(speaker).map { (speaker.uid, $0) } }
        guard let lowest = readings.map(\.1).min() else {
            volume = nil
            return nil
        }
        let differs = readings.contains { abs($0.1 - lowest) > Self.tolerance }
        if differs {
            let text = readings.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
            Self.log.info("Speaker volumes differ (\(text, privacy: .public)); linking both to \(lowest)")
            write(lowest)
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
            guard let speaker = speakers.first, let got = read(speaker) else { return self.volume }
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
        guard let value = read(speaker) else { return }
        if let volume, abs(value - volume) <= Self.tolerance { return }
        Self.log.info("\(uid, privacy: .public) changed to \(value) outside Domine; copying it to the other speaker")
        write(value, except: uid)
        volume = value
        onExternalChange?(value)
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

    private func write(_ value: Float, except skipped: String? = nil) {
        for index in speakers.indices where speakers[index].uid != skipped {
            // Set before writing: the HAL may notify while the write is in progress.
            speakers[index].suppressedUntil = now().advanced(by: Self.suppression)
            let speaker = speakers[index]
            for element in speaker.elements {
                do {
                    try hal.setVolume(value, of: speaker.id, element: element)
                } catch {
                    Self.log.error("Could not set volume of \(speaker.uid, privacy: .public): \(error.description, privacy: .public)")
                }
            }
        }
    }
}
