import Foundation

/// Dropouts per speaker since the session started, keyed by device UID.
struct DropoutCounts: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var overloads = 0
        var disconnects = 0
    }

    var entries: [String: Entry] = [:]
    var sessionStart: Date

    init(sessionStart: Date = Date()) {
        self.sessionStart = sessionStart
    }

    subscript(uid uid: String) -> Entry { entries[uid] ?? Entry() }

    mutating func recordOverload(uid: String) { entries[uid, default: Entry()].overloads += 1 }
    mutating func recordDisconnect(uid: String) { entries[uid, default: Entry()].disconnects += 1 }

    mutating func reset(at date: Date = Date()) {
        entries = [:]
        sessionStart = date
    }
}
