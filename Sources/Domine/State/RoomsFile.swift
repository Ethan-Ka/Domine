import Foundation

/// The `.domine-rooms` file: a versioned envelope around saved rooms.
/// Pure encode, decode, and name merging; the panels live in the UI layer.
enum RoomsFile {
    static let currentVersion = 1
    static let fileExtension = "domine-rooms"

    enum Failure: Error, Equatable {
        case notARoomsFile
        case unsupportedVersion(Int)
    }

    private struct Envelope: Codable {
        var version: Int
        var rooms: [Room]
    }

    private struct VersionOnly: Decodable {
        var version: Int
    }

    static func encode(_ rooms: [Room]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(version: currentVersion, rooms: rooms))
    }

    static func decode(_ data: Data) throws -> [Room] {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(VersionOnly.self, from: data) else {
            throw Failure.notARoomsFile
        }
        guard header.version == currentVersion else { throw Failure.unsupportedVersion(header.version) }
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            throw Failure.notARoomsFile
        }
        return envelope.rooms
    }

    /// Gives each imported room a fresh id and a name that does not collide
    /// with `existingNames` or earlier imports: "Name 2", "Name 3", and so on.
    static func merge(_ imported: [Room], existingNames: [String]) -> [Room] {
        var taken = Set(existingNames)
        return imported.map { room in
            var room = room
            room.id = UUID()
            var name = room.name
            var n = 2
            while taken.contains(name) {
                name = "\(room.name) \(n)"
                n += 1
            }
            taken.insert(name)
            room.name = name
            return room
        }
    }
}
