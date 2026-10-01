/// Which device clocks Domine's aggregate (SPEC section 3.2).
enum AggregateClock: Equatable, Sendable {
    /// Device A is the main sub-device and the clock, with drift
    /// compensation off; Device B is drift compensated against it.
    case leftSpeaker
    /// Another device (for example the system default output, or a future
    /// virtual device) is the clock key. Both speakers are drift compensated
    /// and Device A stays the main sub-device. Not yet verified on hardware.
    case device(uid: String)
}
