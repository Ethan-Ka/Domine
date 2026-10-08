import Foundation

/// Plain text for pasting into a GitHub issue. Pure: everything it prints
/// comes in through `Context` and the snapshot.
enum DiagnosticsReport {
    struct SpeakerInfo: Equatable, Sendable {
        let uid: String
        let name: String
        let transport: String
        let connected: Bool
    }

    struct Context: Equatable, Sendable {
        var appVersion: String
        var build: String
        var macOS: String
        var routingMode: String
        var delayMs: Double
        var overloads: Int?
        var engineState: String
        var lastError: String?
        var speakers: [SpeakerInfo]
    }

    static func make(snapshot: DebugSnapshot?, context c: Context) -> String {
        var lines = [
            "Domine \(c.appVersion) (build \(c.build))",
            "macOS \(c.macOS)",
            "Routing mode: \(c.routingMode)",
            "Engine state: \(c.engineState)",
            "Last error: \(c.lastError ?? "none")",
            String(format: "Delay offset: %.1f ms", c.delayMs),
        ]
        let uids = (snapshot?.speakers.map(\.uid) ?? []) + c.speakers.map(\.uid)
        var seen = Set<String>()
        for uid in uids where seen.insert(uid).inserted {
            let info = c.speakers.first { $0.uid == uid }
            let live = snapshot?.speakers.first { $0.uid == uid }
            lines.append("Speaker \(live?.label ?? "-"): \(info?.name ?? "unknown")")
            lines.append("  UID: \(uid)")
            lines.append("  Transport: \(info?.transport ?? "unknown")")
            lines.append("  Connected: \((info?.connected ?? false) ? "yes" : "no")")
            lines.append("  Reported latency: \(latency(live?.latency, rate: live?.sampleRate))")
            lines.append("  Sample rate: \(hz(live?.sampleRate))")
        }
        let w = snapshot?.window
        lines.append("Aggregate sample rate: \(hz(snapshot?.aggregateRate))")
        lines.append("Clock (effective out/in): \(hz(w?.effectiveSampleRate)) / \(hz(w?.effectiveInputSampleRate))")
        lines.append("Aggregate overloads: \(c.overloads.map(String.init) ?? "n/a")")
        return "```\n" + lines.joined(separator: "\n") + "\n```"
    }

    private static func hz(_ value: Double?) -> String {
        value.map { String(format: "%.1f Hz", $0) } ?? "n/a"
    }

    private static func latency(_ latency: DeviceLatency?, rate: Double?) -> String {
        guard let latency else { return "n/a" }
        var text = "\(latency.totalFrames) frames"
        if let rate, let ms = latency.milliseconds(sampleRate: rate) {
            text += String(format: ", %.1f ms", ms)
        }
        return text
    }
}
