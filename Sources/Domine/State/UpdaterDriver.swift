/// The part of Sparkle's updater that `Updater` uses, so tests can swap it out.
@MainActor
protocol UpdaterDriver: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    /// Starts the updater and calls `onCanCheckChange` whenever a check
    /// becomes possible or stops being possible.
    func start(onCanCheckChange: @escaping @MainActor (Bool) -> Void)
    func checkForUpdates()
}
