import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    let catalog: DeviceCatalog
    let engine: Engine

    /// Selected speakers, by UID.
    var leftUID: String?
    var rightUID: String?

    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    init(hal: any AudioHAL = CoreAudioHAL()) {
        catalog = DeviceCatalog(hal: hal)
        engine = Engine(hal: hal)
    }

    func start() {
        catalog.start()
        chooseDefaultSpeakers()
        guard terminationObserver == nil else { return }
        // Never leave a muting tap behind on quit. AppKit posts this on the
        // main thread; a nil queue runs the block before termination continues.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.stop() }
        }
    }

    /// Picks the two JBL Grips when nothing is selected yet.
    func chooseDefaultSpeakers() {
        guard leftUID == nil, rightUID == nil else { return }
        let grips = catalog.outputs.filter { $0.name == DeviceCatalog.gripName }
        guard grips.count >= 2 else { return }
        leftUID = grips[0].uid
        rightUID = grips[1].uid
    }

    func setRouting(_ on: Bool) {
        if on {
            Task { await engine.start(left: leftUID, right: rightUID) }
        } else {
            engine.stop()
        }
    }
}
