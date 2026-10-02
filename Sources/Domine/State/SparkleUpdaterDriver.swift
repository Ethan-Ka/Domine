import Combine
import Foundation
import Sparkle

/// `UpdaterDriver` backed by Sparkle's standard controller and its default UI.
@MainActor
final class SparkleUpdaterDriver: UpdaterDriver {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private var canCheckObservation: AnyCancellable?

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func start(onCanCheckChange: @escaping @MainActor (Bool) -> Void) {
        controller.startUpdater()
        canCheckObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { value in MainActor.assumeIsolated { onCanCheckChange(value) } }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
