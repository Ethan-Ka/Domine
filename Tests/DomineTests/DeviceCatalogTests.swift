import CoreAudio
import Testing
@testable import Domine

@MainActor
struct DeviceCatalogTests {
    let hal = FakeHAL()
    let catalog: DeviceCatalog

    init() {
        catalog = DeviceCatalog(hal: hal)
    }

    static let gripA = FakeHAL.Device(uid: "60-FD-A6-19-4F-2A:output", name: "JBL Grip")
    static let gripB = FakeHAL.Device(uid: "60-FD-A6-19-9C-11:output", name: "JBL Grip")
    static let builtIn = FakeHAL.Device(
        uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
        transportType: kAudioDeviceTransportTypeBuiltIn)

    @Test func listsOutputsOnStart() {
        hal.add(Self.builtIn)
        hal.add(Self.gripA)
        catalog.start()
        #expect(catalog.outputs.map(\.uid) == [Self.builtIn.uid, Self.gripA.uid])
    }

    @Test func picksUpDevicesAddedAndRemovedAfterStart() {
        catalog.start()
        #expect(catalog.outputs.isEmpty)
        hal.add(Self.gripA)
        hal.add(Self.gripB)
        #expect(catalog.outputs.count == 2)
        hal.remove(uid: Self.gripA.uid)
        #expect(catalog.outputs.map(\.uid) == [Self.gripB.uid])
    }

    @Test func reconnectKeepsUIDButGetsNewID() {
        let first = hal.add(Self.gripA)
        catalog.start()
        hal.remove(uid: Self.gripA.uid)
        let second = hal.add(Self.gripA)
        #expect(first != second)
        #expect(catalog.device(uid: Self.gripA.uid)?.id == second)
    }

    @Test func skipsInputOnlyDevices() {
        hal.add(.init(uid: "mic", name: "Mic", outputChannels: 0))
        hal.add(Self.gripA)
        catalog.start()
        #expect(catalog.outputs.map(\.uid) == [Self.gripA.uid])
    }

    @Test func skipsDomineAggregates() {
        hal.add(.init(uid: DeviceCatalog.domineUIDPrefix + "aggregate.1", name: "Domine", outputChannels: 4))
        hal.add(Self.gripA)
        catalog.start()
        #expect(catalog.outputs.map(\.uid) == [Self.gripA.uid])
    }

    @Test func tracksDefaultOutputByUID() {
        hal.add(Self.builtIn)
        hal.add(Self.gripA)
        hal.setDefault(uid: Self.builtIn.uid)
        catalog.start()
        #expect(catalog.defaultOutputUID == Self.builtIn.uid)
        hal.setDefault(uid: Self.gripA.uid)
        #expect(catalog.defaultOutputUID == Self.gripA.uid)
    }

    @Test func picksUpRenames() {
        hal.add(Self.gripA)
        catalog.start()
        hal.rename(uid: Self.gripA.uid, to: "Grip Left")
        #expect(catalog.outputs.first?.name == "Grip Left")
    }

    @Test func gripPairingHintOnlyWithExactlyOneGrip() {
        catalog.start()
        #expect(!catalog.showsGripPairingHint)
        hal.add(Self.gripA)
        #expect(catalog.showsGripPairingHint)
        hal.add(Self.gripB)
        #expect(!catalog.showsGripPairingHint)
    }

    @Test func recordsNonBadObjectErrors() {
        hal.add(Self.gripA)
        hal.failNextRead = kAudioHardwareUnspecifiedError
        catalog.start()
        #expect(catalog.lastError?.status == kAudioHardwareUnspecifiedError)
        #expect(catalog.outputs.isEmpty)
    }

    @Test func stopRemovesAllListeners() {
        hal.add(Self.gripA)
        catalog.start()
        #expect(hal.listenerCount == 3)  // devices, default output, one name
        catalog.stop()
        #expect(hal.listenerCount == 0)
    }

    @Test func uidSuffixDistinguishesGrips() {
        #expect(OutputDevice.suffix(forUID: Self.gripA.uid) == "4F2A")
        #expect(OutputDevice.suffix(forUID: Self.gripB.uid) == "9C11")
    }
}

struct HALErrorTests {
    @Test func descriptionIncludesFourCCAndSelector() {
        let error = HALError(kAudioHardwareBadObjectError, "AudioObjectGetPropertyData",
                             selector: kAudioDevicePropertyDeviceUID)
        #expect(error.description == "AudioObjectGetPropertyData failed with '!obj' selector 'uid '")
    }
}
