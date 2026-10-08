import XCTest
@testable import Domine

final class BluetoothAddressTests: XCTestCase {
    func testParsesCoreAudioBluetoothUID() {
        XCTAssertEqual(BluetoothAddress(deviceUID: "AA-BB-CC-0D-EE-FF:output")?.string, "aa-bb-cc-0d-ee-ff")
        XCTAssertEqual(BluetoothAddress(deviceUID: "aa-bb-cc-0d-ee-ff")?.string, "aa-bb-cc-0d-ee-ff")
    }

    func testRejectsOtherUIDs() {
        XCTAssertNil(BluetoothAddress(deviceUID: "BuiltInSpeakerDevice"))
        XCTAssertNil(BluetoothAddress(deviceUID: "AppleUSBAudioEngine:Foo:1"))
        XCTAssertNil(BluetoothAddress(deviceUID: "AA-BB-CC-DD-EE:output"))
    }
}
