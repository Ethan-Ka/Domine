import Observation

@MainActor
@Observable
final class AppModel {
    let catalog: DeviceCatalog

    init(hal: any AudioHAL = CoreAudioHAL()) {
        catalog = DeviceCatalog(hal: hal)
    }

    func start() {
        catalog.start()
    }
}
