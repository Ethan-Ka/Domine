/// What the Choose Speaker sheet does in Surround mode.
enum SurroundAssignTarget: Identifiable, Equatable, Sendable {
    /// "Add Speaker…": the chosen output joins the room.
    case add
    /// A card's "Choose Speaker…": the chosen output takes that speaker's
    /// place.
    case replace(uid: String)

    var id: String {
        switch self {
        case .add: "add"
        case .replace(let uid): "replace:" + uid
        }
    }

    /// The speaker being replaced, if any.
    var replacedUID: String? {
        switch self {
        case .add: nil
        case .replace(let uid): uid
        }
    }
}
