/// An entry in the "Excluded apps play through" popup. The label always carries
/// the UID suffix, since two outputs can share a name.
struct ExclusionOutputChoice: Identifiable, Equatable, Sendable {
    let uid: String
    let label: String

    var id: String { uid }

    init(uid: String, name: String) {
        self.uid = uid
        self.label = OutputDevice.menuLabel(name: name, uid: uid)
    }
}
