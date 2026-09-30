/// What the checklist buttons do.
struct WelcomeActions {
    /// Button on a step row: mark JBL unpairing done, open Bluetooth settings,
    /// or request audio capture permission.
    var perform: @MainActor (WelcomeStep.Kind) -> Void = { _ in }
    var continueSetup: @MainActor () -> Void = {}
}
