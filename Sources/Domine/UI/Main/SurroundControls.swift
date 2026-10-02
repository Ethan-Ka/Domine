import Foundation

/// The Surround sliders under the stage (SPEC section 13).
struct SurroundControls: Equatable, Sendable {
    /// Front image width in degrees, 10...90.
    var width: Double = 30
    /// How much goes to the speakers behind the listener, 0...1.
    var level: Double = 1
    /// Turns per second, 0 (off) ... 2.
    var orbitRate: Double = 0
    /// Rotation of the whole sound field in degrees, -180...180.
    var rotation: Double = 0
    /// More Bluetooth speakers than the radio can carry reliably.
    var showsBluetoothWarning = false

    static let widthRange: ClosedRange<Double> = 10...90
    static let orbitRange: ClosedRange<Double> = 0...2
    static let rotationRange: ClosedRange<Double> = -180...180
    static let bluetoothWarning = "More than 4 Bluetooth speakers may drop out"

    var widthText: String { "\(Int(width.rounded()))°" }
    var levelText: String { "\(Int((min(max(level, 0), 1) * 100).rounded()))%" }
    var rotationText: String { "\(Int(rotation.rounded()))°" }

    var orbitText: String { Self.orbitText(orbitRate) }

    /// "Off" at 0, otherwise turns per second like "0.25/s".
    static func orbitText(_ rate: Double) -> String {
        guard rate >= 0.005 else { return "Off" }
        return String(format: "%.2f/s", rate)
    }
}
