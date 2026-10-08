import Foundation
import Testing
@testable import Domine

struct RoomsFileTests {
    @Test func roundTrip() throws {
        let room = Room(name: "Den", mode: .stereo, leftUID: "A", rightUID: "B")
        let decoded = try RoomsFile.decode(RoomsFile.encode([room]))
        #expect(decoded == [room])
    }

    @Test func rejectsOtherVersionAndGarbage() {
        let v2 = Data(#"{"version":2,"rooms":[]}"#.utf8)
        #expect(throws: RoomsFile.Failure.unsupportedVersion(2)) { try RoomsFile.decode(v2) }
        #expect(throws: RoomsFile.Failure.notARoomsFile) { try RoomsFile.decode(Data("hi".utf8)) }
        let bad = Data(#"{"version":1,"rooms":5}"#.utf8)
        #expect(throws: RoomsFile.Failure.notARoomsFile) { try RoomsFile.decode(bad) }
    }

    @Test func nameCollisionsGetSuffixes() {
        let a = Room(name: "Den", mode: .stereo)
        let b = Room(name: "Den", mode: .stereo)
        let merged = RoomsFile.merge([a, b, Room(name: "Patio", mode: .stereo)],
                                     existingNames: ["Den", "Den 2"])
        #expect(merged.map(\.name) == ["Den 3", "Den 4", "Patio"])
        #expect(merged[0].id != a.id)
    }
}
