/// Everything the Choose Speaker sheet shows (docs/mockups/Assign.dc.html).
struct AssignSheetState: Equatable, Sendable {
    var position: SpeakerPosition
    /// Shown under the title, e.g. when two outputs share a name.
    var note: String?
    var rows: [AssignRow]
    /// Shown under the list, e.g. the JBL stereo pairing hint.
    var footnote: String?

    var title: String { "Choose the \(position.title) speaker" }
    var selectedUID: String? { rows.first(where: \.isSelected)?.uid }
}
