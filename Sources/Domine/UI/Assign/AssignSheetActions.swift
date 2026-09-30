/// What the Choose Speaker sheet can ask the model to do.
struct AssignSheetActions: Sendable {
    /// A row was clicked; the owner marks it selected.
    var select: @MainActor @Sendable (_ uid: String) -> Void = { _ in }
    var playTone: @MainActor @Sendable (_ uid: String) -> Void = { _ in }
    var cancel: @MainActor @Sendable () -> Void = {}
    /// "Use This Speaker" with the selected row's UID.
    var confirm: @MainActor @Sendable (_ uid: String) -> Void = { _ in }

    static let none = AssignSheetActions()
}
