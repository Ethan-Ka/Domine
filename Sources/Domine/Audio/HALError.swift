import CoreAudio

/// A non-zero `OSStatus` from Core Audio, with the call and property that produced it.
struct HALError: Error, Equatable, CustomStringConvertible {
    let status: OSStatus
    let operation: String
    let selector: AudioObjectPropertySelector

    init(_ status: OSStatus, _ operation: String, selector: AudioObjectPropertySelector = 0) {
        self.status = status
        self.operation = operation
        self.selector = selector
    }

    var description: String {
        let sel = selector == 0 ? "" : " selector \(FourCC.string(selector))"
        return "\(operation) failed with \(FourCC.string(UInt32(bitPattern: status)))\(sel)"
    }

    /// The device went away between listing it and reading from it.
    var isBadObject: Bool {
        status == kAudioHardwareBadObjectError || status == kAudioHardwareBadDeviceError
    }

    static func check(
        _ status: OSStatus,
        _ operation: String,
        selector: AudioObjectPropertySelector = 0
    ) throws(HALError) {
        if status != noErr { throw HALError(status, operation, selector: selector) }
    }
}
