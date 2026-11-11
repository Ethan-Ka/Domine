/// The master volume's label: a percentage up to 100%, then the boost in dB.
enum VolumeText {
    static func label(_ volume: Double) -> String {
        let v = max(volume, 0)
        guard v > 1 else { return "\(Int((v * 100).rounded()))%" }
        let db = Int(((v - 1) * Double(PairSettings.maxBoostDb)).rounded())
        return db == 0 ? "100%" : "+\(db) dB"
    }

    /// Spoken by VoiceOver.
    static func accessibility(_ volume: Double) -> String {
        let v = max(volume, 0)
        guard v > 1 else { return "\(Int((v * 100).rounded())) percent" }
        let db = Int(((v - 1) * Double(PairSettings.maxBoostDb)).rounded())
        return db == 0 ? "100 percent" : "Boost \(db) decibels"
    }
}
