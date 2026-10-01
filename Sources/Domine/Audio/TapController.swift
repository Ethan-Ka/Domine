import CoreAudio

/// Creates and destroys the system-wide process tap. The tap excludes
/// Domine's own process, so the engine's output is never fed back into it.
struct TapController: Sendable {
    let hal: any AudioHAL

    func create() throws(EngineError) -> ProcessTap {
        let own = try EngineError.hal { () throws(HALError) in try hal.ownProcessObject() }
        guard own != kAudioObjectUnknown else { throw .noOwnProcessObject }
        return try EngineError.hal { () throws(HALError) in try hal.createProcessTap(excluding: [own], muted: true) }
    }

    func destroy(_ tap: ProcessTap) throws(HALError) {
        try hal.destroyProcessTap(tap.id)
    }
}
