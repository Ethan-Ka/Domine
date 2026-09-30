/// Storage key for a device pair, in the form "uidA|uidB".
///
/// The key is order-insensitive: uidA is always the UID that sorts first, so
/// swapping Front Left and Front Right finds the same record. Delay and balance
/// describe the physical speakers (which one lags, which one is louder), not the
/// positions, so after a swap they are flipped rather than reset. `isSwapped`
/// is true when the current Front Left is uidB of the stored record.
struct PairKey: Hashable, Sendable {
    let rawValue: String
    let isSwapped: Bool

    init(leftUID: String, rightUID: String) {
        if rightUID < leftUID {
            rawValue = "\(rightUID)|\(leftUID)"
            isSwapped = true
        } else {
            rawValue = "\(leftUID)|\(rightUID)"
            isSwapped = false
        }
    }
}
