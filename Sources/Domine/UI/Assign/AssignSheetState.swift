/// Everything the Choose Speaker sheet shows (docs/mockups/Assign.dc.html).
struct AssignSheetState: Equatable, Sendable {
    /// The Stereo position being chosen. Unused when `customTitle` is set.
    var position: SpeakerPosition
    var rows: [AssignRow]
    /// Shown under the list, e.g. the JBL stereo pairing hint.
    var footnote: String?
    /// Surround titles the sheet itself ("Add a speaker"), since its speakers
    /// have no fixed position.
    var customTitle: String?
    /// The default button, e.g. "Add Speaker" when adding in Surround.
    var confirmTitle = "Use This Speaker"

    var title: String { customTitle ?? "Choose the \(position.title) speaker" }
    var selectedUID: String? { rows.first(where: \.isSelected)?.uid }
}
