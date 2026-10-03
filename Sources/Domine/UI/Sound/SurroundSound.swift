/// The Sound sheet's Surround part: every speaker's effects and the link.
struct SurroundSound: Equatable, Sendable {
    struct Speaker: Identifiable, Equatable, Sendable {
        /// Device UID.
        var uid: String
        /// Direction title like "Front Left".
        var title: String
        /// Four characters from the UID that tell two "JBL Grip"s apart.
        var suffix: String?
        var effects: PairSettings.SideEffects

        var id: String { uid }
        var label: String { [title, suffix].compactMap { $0 }.joined(separator: " ") }
    }

    var speakers: [Speaker]
    /// While on, every speaker plays the first speaker's effects.
    var isLinked: Bool

    /// The speaker edits go to: the first while linked, else `selection`
    /// when it is still in the set.
    func editedUID(selection: String?) -> String? {
        if !isLinked, let selection, speakers.contains(where: { $0.uid == selection }) { return selection }
        return speakers.first?.uid
    }

    func effects(for uid: String) -> PairSettings.SideEffects {
        speakers.first { $0.uid == uid }?.effects ?? PairSettings.SideEffects()
    }
}
