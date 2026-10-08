import CoreAudio

/// Creates and destroys the system-wide process tap. The tap excludes
/// Domine's own process, so the engine's output is never fed back into it.
struct TapController: Sendable {
    let hal: any AudioHAL

    /// `excluded` are further process objects to leave untapped: the
    /// excluded apps of SPEC 3b, once they are resolved to processes.
    func create(alsoExcluding excluded: [AudioObjectID] = []) throws(EngineError) -> ProcessTap {
        let own = try EngineError.hal { () throws(HALError) in try hal.ownProcessObject() }
        guard own != kAudioObjectUnknown else { throw .noOwnProcessObject }
        return try EngineError.hal { () throws(HALError) in
            try hal.createProcessTap(excluding: [own] + excluded, muted: true)
        }
    }

    /// Points a running tap at a new exclusion list without rebuilding it.
    func updateExclusions(of tap: ProcessTap, alsoExcluding excluded: [AudioObjectID]) throws(EngineError) {
        let own = try EngineError.hal { () throws(HALError) in try hal.ownProcessObject() }
        guard own != kAudioObjectUnknown else { throw .noOwnProcessObject }
        try EngineError.hal { () throws(HALError) in
            try hal.setProcessTapExclusions(tap.id, excluding: [own] + excluded)
        }
    }

    /// A muting tap of one app's processes, mixed into the aggregate beside the global tap.
    func createApp(processes: [AudioObjectID]) throws(EngineError) -> ProcessTap {
        try EngineError.hal { () throws(HALError) in try hal.createProcessTap(including: processes) }
    }

    func destroy(_ tap: ProcessTap) throws(HALError) {
        try hal.destroyProcessTap(tap.id)
    }
}
