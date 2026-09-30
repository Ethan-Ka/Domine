import CoreAudio

/// An IOProc registered on a device. `bits` is the opaque `AudioDeviceIOProcID`
/// as an integer, so the handle stays Sendable and a fake HAL can mint its own.
struct IOProcHandle: Hashable, Sendable {
    let device: AudioObjectID
    let bits: UInt
}
