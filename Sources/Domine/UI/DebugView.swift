import SwiftUI

/// Read-only window of live audio values (SPEC section 6). Refreshes once a
/// second while open.
struct DebugView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            DebugContentView(snapshot: model.engine.diagnostics?.snapshot(),
                             onResetCounts: { model.engine.diagnostics?.resetDropoutCounts() })
        }
    }
}

/// The layout, separate from the engine so it renders from sample values.
struct DebugContentView: View {
    let snapshot: DebugSnapshot?
    var onResetCounts: () -> Void = {}

    var body: some View {
        Form {
            if let snapshot {
                ForEach(Array(snapshot.speakers.enumerated()), id: \.offset) { _, speaker in
                    Section("Speaker \(speaker.label)") {
                        row("UID", speaker.uid)
                        row("Sample rate", Self.hz(speaker.sampleRate))
                        row("Latency", Self.latency(speaker.latency, rate: speaker.sampleRate))
                    }
                }
                Section("Dropouts") {
                    ForEach(Array(snapshot.speakers.enumerated()), id: \.offset) { _, speaker in
                        let entry = snapshot.dropouts[uid: speaker.uid]
                        LabeledContent {
                            HStack(spacing: 12) {
                                Text("Overloads \(entry.overloads)")
                                Text("Disconnects \(entry.disconnects)")
                                    .foregroundStyle(entry.disconnects > 0 ? Color.red : Color.primary)
                            }
                            .monospacedDigit()
                        } label: {
                            HStack(spacing: 6) {
                                Text(speaker.label)
                                Text(String(speaker.uid.prefix(17).suffix(5)))
                                    .foregroundStyle(.secondary)
                                    .monospaced()
                            }
                        }
                    }
                    HStack {
                        Text("Since \(snapshot.dropouts.sessionStart.formatted(date: .omitted, time: .standard))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset Counts", action: onResetCounts)
                    }
                }
                Section("Aggregate") {
                    row("Sample rate", Self.hz(snapshot.aggregateRate))
                    row("Tap format", snapshot.tapFormat ?? "n/a")
                }
                if let k = snapshot.kernel {
                    Section("Kernel layout") {
                        row("Sample rate", Self.hz(k.sampleRate))
                        row("Input", "buffer \(k.inFirstBuffer), \(k.inputChannels) ch, "
                            + (k.nonInterleaved ? "non-interleaved" : "interleaved"))
                        row("Output offsets", "A \(k.outA), B \(k.outB)")
                        row("Frames", "max \(k.maxFrames), fifo \(k.fifoCapacity)")
                    }
                }
                Section("Timing") {
                    let w = snapshot.window
                    row("Frames in", Self.rate(w?.inputFramesPerSecond, "frames/s"))
                    row("Frames out", Self.rate(w?.framesPerSecond, "frames/s"))
                    row("Effective rate in", Self.rate(w?.effectiveInputSampleRate, "Hz"))
                    row("Effective rate out", Self.rate(w?.effectiveSampleRate, "Hz"))
                }
            } else {
                Text("Engine stopped")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 360)
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }

    private static func hz(_ value: Double?) -> String {
        value.map { String(format: "%.1f Hz", $0) } ?? "n/a"
    }

    private static func rate(_ value: Double?, _ unit: String) -> String {
        value.map { String(format: "%.1f %@", $0, unit) } ?? "n/a"
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

extension DebugSnapshot {
    static let sample = DebugSnapshot(
        speakers: [
            Speaker(label: "A", uid: "00-11-22-33-44-55:output", sampleRate: 48000,
                    latency: DeviceLatency(deviceFrames: 0, safetyOffsetFrames: 0, streamFrames: 9600)),
            Speaker(label: "B", uid: "66-77-88-99-AA-BB:output", sampleRate: 48000,
                    latency: DeviceLatency(deviceFrames: 0, safetyOffsetFrames: 0, streamFrames: 9600)),
        ],
        aggregateRate: 48000,
        tapFormat: "48000.0 Hz 2 ch float32 interleaved",
        kernel: nil,
        window: nil)
}
