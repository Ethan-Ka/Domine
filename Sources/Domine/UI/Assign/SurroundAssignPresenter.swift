import Observation

/// Presentation state for the Surround Choose Speaker sheet. Held by
/// `MainView`, since Surround speakers have no `SpeakerPosition` for
/// `AppModel.assignPosition`.
@MainActor
@Observable
final class SurroundAssignPresenter {
    var target: SurroundAssignTarget?
    /// The row picked in the sheet.
    var selection: String?

    init() {}

    func present(_ target: SurroundAssignTarget) {
        selection = target.replacedUID
        self.target = target
    }

    func dismiss() {
        target = nil
    }
}
