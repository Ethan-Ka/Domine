/// The menu bar item: the icon, with a warning badge while a speaker has
/// dropped out, and optional text beside it.
struct MenuBarLabelState: Equatable, Sendable {
    /// Mono fallback, or Surround with speakers missing.
    var showsWarning = false
    /// "62%", "Muted", or "Stereo"; nil for icon only.
    var text: String?
}
