/// Why the engine could not start.
enum EngineError: Error, Equatable, CustomStringConvertible {
    case hal(HALError)
    /// A Bluetooth sub-device exposes input streams. Opening it would switch
    /// the speaker to the hands-free profile (SPEC section 9).
    case bluetoothInput(uid: String)
    case noOwnProcessObject
    case layoutMismatch(String)
    case invalidSampleRate(Double)
    case kernelUnavailable

    var description: String {
        switch self {
        case .hal(let error):
            error.description
        case .bluetoothInput(let uid):
            "Bluetooth device \(uid) has input streams; Domine never opens Bluetooth input"
        case .noOwnProcessObject:
            "Could not find Domine's own audio process, so the tap cannot exclude it"
        case .layoutMismatch(let detail):
            "Unexpected aggregate stream layout (\(detail))"
        case .invalidSampleRate(let rate):
            "Aggregate reports an invalid sample rate (\(rate) Hz)"
        case .kernelUnavailable:
            "Could not allocate the render kernel"
        }
    }

    /// Runs a HAL call, wrapping its error.
    static func hal<T>(_ body: () throws(HALError) -> T) throws(EngineError) -> T {
        do {
            return try body()
        } catch {
            throw .hal(error)
        }
    }
}
