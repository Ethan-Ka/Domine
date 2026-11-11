/// When `SpeakerReconnector` tries a dropped speaker: after `firstDelay`,
/// then every `retryDelay`, until `giveUpAfter` has passed.
struct ReconnectTiming: Equatable, Sendable {
    var firstDelay: Duration = .seconds(5)
    var retryDelay: Duration = .seconds(30)
    var giveUpAfter: Duration = .seconds(600)
}
