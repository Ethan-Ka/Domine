import CoreAudio
import Foundation
import Testing
@testable import Domine

struct StaleAggregateCleanerTests {
    private func aggregate(_ hal: FakeHAL, _ uid: String) throws {
        _ = try hal.createAggregateDevice([kAudioAggregateDeviceUIDKey: uid, kAudioAggregateDeviceNameKey: "x"])
    }

    @Test @MainActor func destroysStaleAggregatesOnly() throws {
        let hal = FakeHAL()
        let prefix = StaleAggregateCleaner.uidPrefix
        try aggregate(hal, prefix + "A")
        try aggregate(hal, prefix + "B")
        try aggregate(hal, DeviceCatalog.domineUIDPrefix + "capturecheck.C")
        hal.add(.init(uid: "com.ethankawley.Domine.VirtualOutput", name: "Domine"))
        hal.add(.init(uid: "JBL-1", name: "JBL Grip"))
        #expect(StaleAggregateCleaner.clean(hal: hal) == 2)
        let uids = try hal.deviceIDs().map { try hal.uid(of: $0) }
        #expect(uids == [DeviceCatalog.domineUIDPrefix + "capturecheck.C",
                         "com.ethankawley.Domine.VirtualOutput", "JBL-1"])
        #expect(hal.ops.filter { $0 == .destroyAggregate }.count == 2)
    }

    @Test @MainActor func oneFailureDoesNotStopTheRest() throws {
        let hal = FakeHAL()
        let prefix = StaleAggregateCleaner.uidPrefix
        // Not a real aggregate in the fake, so destroying it fails.
        hal.add(.init(uid: prefix + "stuck", name: "stuck"))
        try aggregate(hal, prefix + "after")
        #expect(StaleAggregateCleaner.clean(hal: hal) == 1)
        let uids = try hal.deviceIDs().map { try hal.uid(of: $0) }
        #expect(uids == [prefix + "stuck"])
    }
}
