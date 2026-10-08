import DomineDSP

/// A read-only copy of the running engine's values, for the Debug window.
/// A nil value means the read failed or there is nothing to read yet.
struct DebugSnapshot: Equatable, Sendable {
    struct Speaker: Equatable, Sendable {
        let label: String
        let uid: String
        let sampleRate: Double?
        let latency: DeviceLatency?
    }

    struct Kernel: Equatable, Sendable {
        let sampleRate: Double
        let inFirstBuffer: UInt32
        let outA: UInt32
        let outB: UInt32
        let inputChannels: UInt32
        let nonInterleaved: Bool
        let fifoCapacity: UInt32
        let maxFrames: UInt32

        init(_ s: DomineKernelStats) {
            sampleRate = s.sampleRate
            inFirstBuffer = s.layoutInFirstBuffer
            outA = s.layoutOutA
            outB = s.layoutOutB
            inputChannels = s.inputChannelsPerFrame
            nonInterleaved = s.inputNonInterleaved != 0
            fifoCapacity = s.fifoCapacity
            maxFrames = s.maxFrames
        }
    }

    var speakers: [Speaker]
    var aggregateRate: Double?
    var tapFormat: String?
    var kernel: Kernel?
    var window: DiagnosticsWindow?
    var dropouts = DropoutCounts()
}
