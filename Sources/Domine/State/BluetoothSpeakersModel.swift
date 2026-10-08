import Observation

/// State behind the Bluetooth Speakers window: remembered speakers, other
/// paired audio devices, and a search for new ones. All radio work goes
/// through `BluetoothRadio`.
@Observable @MainActor
final class BluetoothSpeakersModel {
    /// Speakers Domine keeps across launches, in the order they were added.
    private(set) var remembered: [RememberedSpeaker]
    /// Paired audio devices as the radio last reported them.
    private(set) var paired: [BluetoothSpeaker] = []
    /// Unpaired devices found by the current or last search.
    private(set) var nearby: [BluetoothSpeaker] = []
    private(set) var isSearching = false
    /// True once a search has run, so an empty Nearby list can say so.
    private(set) var hasSearched = false
    /// Addresses with a connect, disconnect, or pair in flight.
    private(set) var busy: Set<String> = []
    var lastError: String?

    @ObservationIgnored private let radio: any BluetoothRadio
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var searchID = 0

    init(radio: any BluetoothRadio, store: SettingsStore) {
        self.radio = radio
        self.store = store
        remembered = store.rememberedSpeakers
    }

    /// Remembered speakers with their live state. One that is not paired or
    /// not in range shows as not connected.
    var mySpeakers: [BluetoothSpeaker] {
        remembered.compactMap { entry in
            guard let address = BluetoothAddress(deviceUID: entry.address) else { return nil }
            if let live = paired.first(where: { $0.address == address }) { return live }
            return BluetoothSpeaker(address: address, name: entry.name, isPaired: false, isConnected: false)
        }
    }

    /// Paired audio devices not in My Speakers.
    var otherPaired: [BluetoothSpeaker] {
        paired.filter { !isRemembered($0.address) }
    }

    func isRemembered(_ address: BluetoothAddress) -> Bool {
        remembered.contains { $0.address == address.string }
    }

    func refresh() {
        paired = radio.pairedSpeakers()
        nearby.removeAll { speaker in paired.contains { $0.address == speaker.address } }
    }

    /// Clears Nearby and starts a search. Nothing starts on its own.
    func search() {
        radio.stopSearch()
        searchID += 1
        let id = searchID
        nearby = []
        hasSearched = true
        isSearching = true
        radio.startSearch(
            found: { [weak self] speaker in
                guard let self, self.searchID == id else { return }
                self.addNearby(speaker)
            },
            finished: { [weak self] in
                guard let self, self.searchID == id else { return }
                self.isSearching = false
            })
    }

    func stop() {
        guard isSearching else { return }
        searchID += 1
        radio.stopSearch()
        isSearching = false
    }

    func connect(_ address: BluetoothAddress) async {
        await run(address, verb: "connect to") { await $0.connect(address) }
    }

    func disconnect(_ address: BluetoothAddress) async {
        await run(address, verb: "disconnect", remembersOnSuccess: false) { await $0.disconnect(address) }
    }

    /// Pairs and connects; on success the speaker leaves Nearby.
    func pair(_ address: BluetoothAddress) async {
        await run(address, verb: "pair with") { await $0.pair(address) }
    }

    /// Adds a speaker to My Speakers. UIDs that are not Bluetooth addresses
    /// are ignored. A known speaker keeps its place and takes the new name.
    func remember(uid: String, name: String) {
        guard let address = BluetoothAddress(deviceUID: uid) else { return }
        remember(address, name: name)
    }

    /// Removes a speaker from Domine's list only; macOS stays paired.
    func forget(_ address: BluetoothAddress) {
        remembered.removeAll { $0.address == address.string }
        store.rememberedSpeakers = remembered
    }

    private func remember(_ address: BluetoothAddress, name: String) {
        if let index = remembered.firstIndex(where: { $0.address == address.string }) {
            guard remembered[index].name != name, !name.isEmpty else { return }
            remembered[index].name = name
        } else {
            remembered.append(RememberedSpeaker(address: address.string, name: name))
        }
        store.rememberedSpeakers = remembered
    }

    private func addNearby(_ speaker: BluetoothSpeaker) {
        guard !nearby.contains(where: { $0.address == speaker.address }),
              !paired.contains(where: { $0.address == speaker.address }) else { return }
        nearby.append(speaker)
    }

    private func name(of address: BluetoothAddress) -> String {
        let all = paired + nearby
        if let speaker = all.first(where: { $0.address == address }) { return speaker.name }
        return remembered.first { $0.address == address.string }?.name ?? "speaker"
    }

    private func run(_ address: BluetoothAddress, verb: String, remembersOnSuccess: Bool = true,
                     _ action: @MainActor (any BluetoothRadio) async -> Bool) async {
        guard !busy.contains(address.string) else { return }
        let name = name(of: address)
        lastError = nil
        busy.insert(address.string)
        let succeeded = await action(radio)
        busy.remove(address.string)
        if succeeded {
            if remembersOnSuccess { remember(address, name: name) }
            nearby.removeAll { $0.address == address }
        } else {
            let suffix = OutputDevice.suffix(forUID: address.string)
            lastError = "Couldn't \(verb) \(name) (\(suffix))."
        }
        refresh()
    }
}
