/// One message on the stage: how serious it is, what it says, and an
/// optional button.
struct StageBannerState: Equatable, Sendable, Identifiable {
    enum Severity: Int, Equatable, Sendable, Comparable {
        case info, warning, error
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    enum Action: Equatable, Sendable {
        /// Reconnect that speaker; with no UID, turn routing on again.
        case reconnect(uid: String?)
        case openSettings
    }

    var severity: Severity
    var text: String
    var action: Action?
    /// Whether the banner offers a close button.
    var isDismissible: Bool

    /// Changes when the message changes, so a dismissed banner stays away
    /// until something different needs saying.
    var id: String { "\(severity.rawValue):\(text)" }

    init(severity: Severity, text: String, action: Action? = nil, isDismissible: Bool = true) {
        self.severity = severity
        self.text = text
        self.action = action
        self.isDismissible = isDismissible
    }

    /// Speakers at or below this battery level raise a warning.
    static let lowBatteryPercent = 15

    /// The banner to show, most serious first.
    static func choose(
        routingFailed: Bool,
        monoFallbackText: String?,
        monoFallbackReconnectUID: String?,
        phoneTakeoverText: String?,
        volumeKeysNeedAccessibility: Bool,
        speakers: [SpeakerCardState],
        pairingHint: String?
    ) -> StageBannerState? {
        if routingFailed {
            return StageBannerState(
                severity: .error, text: "Could not start routing", action: .reconnect(uid: nil),
                isDismissible: false)
        }
        if let text = monoFallbackText {
            return StageBannerState(
                severity: .warning, text: text, action: .reconnect(uid: monoFallbackReconnectUID),
                isDismissible: false)
        }
        if let text = phoneTakeoverText {
            return StageBannerState(severity: .warning, text: text, isDismissible: false)
        }
        if let text = lowBatteryText(speakers) {
            return StageBannerState(severity: .warning, text: text)
        }
        if volumeKeysNeedAccessibility {
            return StageBannerState(
                severity: .warning, text: "Volume keys need Accessibility access.", action: .openSettings)
        }
        if let text = pairingHint {
            return StageBannerState(severity: .info, text: text)
        }
        return nil
    }

    static func lowBatteryText(_ speakers: [SpeakerCardState]) -> String? {
        let low = speakers.filter { card in
            card.connection == .connected && (card.batteryPercent.map { $0 <= lowBatteryPercent } ?? false)
        }
        guard let first = low.first, let percent = first.batteryPercent else { return nil }
        if low.count == 1 { return "\(first.title) battery is at \(percent)%." }
        return "\(low.count) speakers are low on battery."
    }
}
