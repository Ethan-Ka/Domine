/// Keep-alive tone tuning pushed to the stereo and surround kernels
/// (`domine_kernel_set_keep_alive_params`). The defaults equal the kernels' own.
struct KeepAliveParams: Equatable, Sendable {
    /// Seconds of silence before the tone.
    var holdSeconds: Double = 2
    var frequencyHz: Double = 15
    /// Linear peak amplitude (1e-3 is -60 dBFS).
    var amplitude: Double = 1.0e-3
}
