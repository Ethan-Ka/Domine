import CoreAudio
import os

/// Destroys private aggregates a crashed run left behind (SPEC section 7).
/// Matches only UIDs under `domineUIDPrefix + "aggregate."`, so the virtual
/// output and the capture-check aggregate are never touched.
enum StaleAggregateCleaner {
    nonisolated private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "Engine")
    nonisolated static let uidPrefix = DeviceCatalog.domineUIDPrefix + "aggregate."

    /// Returns how many aggregates were destroyed. One failure does not stop the rest.
    @discardableResult
    static func clean(hal: any AudioHAL) -> Int {
        let ids: [AudioObjectID]
        do {
            ids = try hal.deviceIDs()
        } catch {
            log.error("Stale aggregate scan failed: \(error.description, privacy: .public)")
            return 0
        }
        var destroyed = 0
        for id in ids {
            let uid: String
            do {
                uid = try hal.uid(of: id)
            } catch {
                if !error.isBadObject {
                    log.error("Stale aggregate scan could not read a UID: \(error.description, privacy: .public)")
                }
                continue
            }
            guard uid.hasPrefix(uidPrefix) else { continue }
            do {
                try hal.destroyAggregateDevice(id)
                destroyed += 1
                log.notice("Destroyed stale aggregate \(uid, privacy: .public)")
            } catch {
                log.error("Could not destroy stale aggregate \(uid, privacy: .public): \(error.description, privacy: .public)")
            }
        }
        return destroyed
    }
}
