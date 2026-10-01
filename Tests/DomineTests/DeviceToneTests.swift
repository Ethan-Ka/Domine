import CoreAudio
import Foundation
import Testing
@testable import Domine

@MainActor
struct DeviceToneTests {
    let hal = FakeHAL()

    @Test func playsOnTheDeviceAloneThenTearsDownInReverse() async {
        hal.add(.init(uid: "60-FD-A6-19-4F-2A:output", name: "JBL Grip"))
        let player = DeviceTonePlayer(hal: hal)
        player.wait = {}
        await player.run(uid: "60-FD-A6-19-4F-2A:output")
        #expect(hal.ops == [.createIOProc, .start, .stop, .destroyIOProc])
    }

    @Test func missingDeviceDoesNothing() async {
        let player = DeviceTonePlayer(hal: hal)
        player.wait = {}
        await player.run(uid: "gone")
        #expect(hal.ops.isEmpty)
    }

    @Test func failedStartStillDestroysTheIOProc() async {
        hal.add(.init(uid: "a", name: "A"))
        hal.failures = [.start: kAudioHardwareUnspecifiedError]
        let player = DeviceTonePlayer(hal: hal)
        player.wait = {}
        await player.run(uid: "a")
        #expect(hal.ops == [.createIOProc, .destroyIOProc])
    }
}
