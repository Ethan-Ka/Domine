/// Everything Settings > Exclusions shows. The view edits it through a binding.
struct ExclusionsState: Equatable, Sendable {
    var items: [ExclusionItem] = []
    /// Offered in the add menu until added (SPEC 3b). None are excluded by default.
    var suggestions: [ExclusionItem] = Self.defaultSuggestions
    /// nil means the previous output from SPEC 4c.
    var playThroughDeviceUID: String?
    var outputChoices: [ExclusionOutputChoice] = []

    static let defaultSuggestions = [
        ExclusionItem(bundleID: "com.apple.FaceTime", appName: "FaceTime"),
        ExclusionItem(bundleID: "us.zoom.xos", appName: "zoom.us"),
        ExclusionItem(bundleID: "com.microsoft.teams2", appName: "Microsoft Teams"),
        ExclusionItem(bundleID: "com.hnc.Discord", appName: "Discord"),
    ]

    /// Suggestions that are not in the list yet.
    var availableSuggestions: [ExclusionItem] {
        suggestions.filter { suggestion in !items.contains { $0.bundleID == suggestion.bundleID } }
    }

    mutating func add(_ item: ExclusionItem) {
        guard !items.contains(where: { $0.bundleID == item.bundleID }) else { return }
        items.append(item)
    }

    mutating func remove(bundleIDs: Set<String>) {
        items.removeAll { bundleIDs.contains($0.bundleID) }
    }
}
