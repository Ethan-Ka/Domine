/// An entry in the "Excluded apps play through" popup. The label always carries
/// the UID suffix, since two outputs can share a name.
struct ExclusionOutputChoice: Identifiable, Equatable, Sendable {
    let uid: String
    let label: String

    var id: String { uid }

    /// A saved choice whose device is not connected keeps its place in the
    /// popup, marked as such, so the saved setting is shown and not lost.
    init(uid: String, name: String, isConnected: Bool = true) {
        self.uid = uid
        let label = OutputDevice.menuLabel(name: name, uid: uid)
        self.label = isConnected ? label : "\(label), not connected"
    }
}
