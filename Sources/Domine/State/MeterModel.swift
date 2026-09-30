import Foundation
import Observation

/// Displayed peak levels for the two speaker cards (SPEC section 3a).
///
/// `start(reader:)` polls the reader at 30 Hz on the main actor and runs each
/// value through `MeterBallistics`. The reader returns the linear peaks for
/// position A and position B; it will wrap `domine_kernel_peak`.
@MainActor
@Observable
final class MeterModel {
    static let pollInterval: Duration = .nanoseconds(1_000_000_000 / 30)

    /// Displayed level for position A (left speaker), 0...1.
    private(set) var levelA: Float = 0
    /// Displayed level for position B (right speaker), 0...1.
    private(set) var levelB: Float = 0

    var isRunning: Bool { task != nil }

    @ObservationIgnored private var ballisticsA = MeterBallistics()
    @ObservationIgnored private var ballisticsB = MeterBallistics()
    @ObservationIgnored private var reader: (@MainActor () -> (Float, Float))?
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {}

    /// Starts polling. Calling start again replaces the reader and restarts.
    func start(reader: @escaping @MainActor () -> (Float, Float)) {
        stop()
        self.reader = reader
        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: MeterModel.pollInterval)
                guard !Task.isCancelled, let self else { return }
                let now = clock.now
                let elapsed = (now - last).components
                last = now
                self.tick(dt: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            }
        }
    }

    /// Stops polling and resets both levels to 0.
    func stop() {
        task?.cancel()
        task = nil
        reader = nil
        ballisticsA.reset()
        ballisticsB.reset()
        levelA = 0
        levelB = 0
    }

    /// One poll: reads both peaks and advances the ballistics by `dt` seconds.
    /// Does nothing when no reader is set.
    func tick(dt: TimeInterval) {
        guard let reader else { return }
        let (peakA, peakB) = reader()
        levelA = ballisticsA.update(peak: peakA, dt: dt)
        levelB = ballisticsB.update(peak: peakB, dt: dt)
    }
}
