import Testing
@testable import Domine

struct DiagnosticsReportTests {
    @Test func fixedSnapshotGivesExactText() {
        let snapshot = DebugSnapshot(
            speakers: [
                .init(label: "A", uid: "00-11:output", sampleRate: 48000,
                      latency: DeviceLatency(deviceFrames: 0, safetyOffsetFrames: 0, streamFrames: 9600)),
            ],
            aggregateRate: 48000, tapFormat: nil, kernel: nil, window: nil)
        let context = DiagnosticsReport.Context(
            appVersion: "0.1.0", build: "1", macOS: "14.4.0", routingMode: "Stereo",
            delayMs: 12.5, overloads: 2, engineState: "running", lastError: nil,
            speakers: [.init(uid: "00-11:output", name: "JBL Grip", transport: "Bluetooth", connected: true)])
        let expected = """
        ```
        Domine 0.1.0 (build 1)
        macOS 14.4.0
        Routing mode: Stereo
        Engine state: running
        Last error: none
        Delay offset: 12.5 ms
        Speaker A: JBL Grip
          UID: 00-11:output
          Transport: Bluetooth
          Connected: yes
          Reported latency: 9600 frames, 200.0 ms
          Sample rate: 48000.0 Hz
        Aggregate sample rate: 48000.0 Hz
        Clock (effective out/in): n/a / n/a
        Aggregate overloads: 2
        ```
        """
        #expect(DiagnosticsReport.make(snapshot: snapshot, context: context) == expected)
    }
}
