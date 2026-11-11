import Foundation

/// A named set of the surround field controls: width, surround level, the
/// spatial upmixer, rotation, orbit and mono. It holds no speakers, offsets,
/// trims, distances or effects, so it works with any room. (`SurroundPreset`
/// is the older speaker layout menu.)
struct SurroundFieldPreset: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var width: Float = 30
    var surroundLevel: Float = 0.7
    var spatialAmount: Float = 0.6
    var spatialRoomMs: Float = 15
    var rotation: Float = 0
    var orbitRate: Float = 0
    var mono = false

    var id: String { name }

    static let music = SurroundFieldPreset(name: "Music")
    static let movie = SurroundFieldPreset(
        name: "Movie", width: 50, surroundLevel: 1.1, spatialAmount: 0.8, spatialRoomMs: 20)
    static let voice = SurroundFieldPreset(
        name: "Voice", width: 15, surroundLevel: 0.25, spatialAmount: 0.3, spatialRoomMs: 10)
    static let builtIn: [SurroundFieldPreset] = [.music, .movie, .voice]

    static func isBuiltInName(_ name: String) -> Bool {
        builtIn.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    init(name: String, width: Float = 30, surroundLevel: Float = 0.7, spatialAmount: Float = 0.6,
         spatialRoomMs: Float = 15, rotation: Float = 0, orbitRate: Float = 0, mono: Bool = false) {
        self.name = name
        self.width = width
        self.surroundLevel = surroundLevel
        self.spatialAmount = spatialAmount
        self.spatialRoomMs = spatialRoomMs
        self.rotation = rotation
        self.orbitRate = orbitRate
        self.mono = mono
    }

    /// The field controls of `settings` under `name`.
    init(name: String, from settings: SurroundSettings) {
        self.init(name: name, width: settings.width, surroundLevel: settings.surroundLevel,
                  spatialAmount: settings.spatialAmount, spatialRoomMs: settings.spatialRoomMs,
                  rotation: settings.rotation, orbitRate: settings.orbitRate, mono: settings.mono)
    }

    /// Writes only the field controls; everything else is left alone.
    func apply(to settings: inout SurroundSettings) {
        settings.width = width
        settings.surroundLevel = surroundLevel
        settings.spatialAmount = spatialAmount
        settings.spatialRoomMs = spatialRoomMs
        settings.rotation = rotation
        settings.orbitRate = orbitRate
        settings.mono = mono
    }

    /// Whether `settings` has exactly these field values.
    func matches(_ settings: SurroundSettings) -> Bool {
        var copy = settings
        apply(to: &copy)
        copy.sanitize()
        return copy == settings
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case name, width, surroundLevel, spatialAmount, spatialRoomMs, rotation, orbitRate, mono
    }

    /// Missing fields take the Music values and values are clamped into
    /// range. A missing name fails the entry so the store can drop it.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SurroundFieldPreset(name: "")
        name = try c.decode(String.self, forKey: .name)
        width = (try? c.decodeIfPresent(Float.self, forKey: .width)) ?? d.width
        surroundLevel = (try? c.decodeIfPresent(Float.self, forKey: .surroundLevel)) ?? d.surroundLevel
        spatialAmount = (try? c.decodeIfPresent(Float.self, forKey: .spatialAmount)) ?? d.spatialAmount
        spatialRoomMs = (try? c.decodeIfPresent(Float.self, forKey: .spatialRoomMs)) ?? d.spatialRoomMs
        rotation = (try? c.decodeIfPresent(Float.self, forKey: .rotation)) ?? d.rotation
        orbitRate = (try? c.decodeIfPresent(Float.self, forKey: .orbitRate)) ?? d.orbitRate
        mono = (try? c.decodeIfPresent(Bool.self, forKey: .mono)) ?? d.mono
        var probe = SurroundSettings()
        apply(to: &probe)
        probe.sanitize()
        width = probe.width
        surroundLevel = probe.surroundLevel
        spatialAmount = probe.spatialAmount
        spatialRoomMs = probe.spatialRoomMs
        rotation = probe.rotation
        orbitRate = probe.orbitRate
    }
}
