import CoreAudio
import os

/// Turns the exclusion list (SPEC 3b) into the Core Audio process objects the
/// tap should leave alone, and reports when that set changes. Changes are
/// debounced so a burst (an app launching several helper processes) causes
/// one tap rebuild.
@MainActor
final class ExclusionResolver {
    private static let log = Logger(subsystem: "com.ethankawley.Domine", category: "Exclusions")

    private let hal: any AudioHAL
    private let debounce: Duration
    private let sleep: @MainActor (Duration) async -> Void
    private var exclusions: [AppExclusion] = []
    private var tokens: [HALListenerToken] = []
    private var inputTokens: [HALListenerToken] = []
    private var pending: Task<Void, Never>?
    private var started = false
    private var loggedVirtualDefault = false

    /// The set last reported, sorted.
    private(set) var effective: [AudioObjectID] = []
    /// Called with the new effective set when it changes.
    var onChange: (@MainActor ([AudioObjectID]) async -> Void)?
    /// True while the default output is the Domine virtual device.
    var defaultOutputIsVirtual: @MainActor () -> Bool = { false }

    init(hal: any AudioHAL, debounce: Duration = .milliseconds(500),
         sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.hal = hal
        self.debounce = debounce
        self.sleep = sleep
    }

    /// Resolves right away (no debounce) and starts listening. Returns the initial set.
    func start(exclusions: [AppExclusion]) -> [AudioObjectID] {
        stop()
        self.exclusions = exclusions
        started = true
        do {
            tokens.append(try hal.addListener(.processObjects) { [weak self] in self?.schedule() })
        } catch {
            Self.log.error("\(error.description, privacy: .public)")
        }
        effective = resolve()
        refreshInputListeners()
        return effective
    }

    func stop() {
        started = false
        pending?.cancel()
        pending = nil
        tokens.forEach { $0.cancel() }
        tokens = []
        inputTokens.forEach { $0.cancel() }
        inputTokens = []
    }

    func update(exclusions new: [AppExclusion]) {
        guard new != exclusions else { return }
        exclusions = new
        schedule()
    }

    /// Core Audio process objects whose bundle ID is an excluded app's, or a
    /// helper of it (`<bundle ID>.something`), filtered by each mode. Sorted.
    func resolve() -> [AudioObjectID] {
        guard !exclusions.isEmpty else { return [] }
        var result = Set<AudioObjectID>()
        do throws(HALError) {
            for process in try hal.processObjects() {
                let bundleID: String
                do { bundleID = try hal.processBundleID(of: process) } catch { continue }
                guard let exclusion = match(bundleID) else { continue }
                switch exclusion.mode {
                case .always:
                    result.insert(process)
                case .onlyDuringCalls:
                    do {
                        if try hal.processIsRunningInput(of: process) { result.insert(process) }
                    } catch {
                        Self.log.error("\(error.description, privacy: .public)")
                    }
                }
            }
        } catch {
            Self.log.error("Could not list audio processes: \(error.description, privacy: .public)")
        }
        return result.sorted()
    }

    private func match(_ bundleID: String) -> AppExclusion? {
        exclusions.first { bundleID == $0.bundleID || bundleID.hasPrefix($0.bundleID + ".") }
    }

    private func schedule() {
        guard started else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            await sleep(debounce)
            guard !Task.isCancelled else { return }
            await settle()
        }
    }

    private func settle() async {
        refreshInputListeners()
        let new = resolve()
        guard new != effective else { return }
        effective = new
        if !new.isEmpty, !loggedVirtualDefault, defaultOutputIsVirtual() {
            loggedVirtualDefault = true
            Self.log.warning("Exclusions are active while the default output is the Domine virtual device; excluded apps are silent (SPEC 3b open issue)")
        }
        await onChange?(new)
    }

    /// One input-running listener per running process of an app in "Only during calls" mode.
    private func refreshInputListeners() {
        inputTokens.forEach { $0.cancel() }
        inputTokens = []
        guard exclusions.contains(where: { $0.mode == .onlyDuringCalls }),
              let processes = try? hal.processObjects() else { return }
        for process in processes {
            guard let id = try? hal.processBundleID(of: process), match(id)?.mode == .onlyDuringCalls else { continue }
            do {
                inputTokens.append(try hal.addListener(.processIsRunningInput(process)) { [weak self] in self?.schedule() })
            } catch {
                Self.log.error("\(error.description, privacy: .public)")
            }
        }
    }
}
