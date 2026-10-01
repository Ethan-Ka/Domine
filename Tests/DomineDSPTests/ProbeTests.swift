import CoreAudio
import DomineDSP
import Testing

/// The audio capture probe's IOProc: silence leaves the flag clear, any
/// non-zero sample sets it, reset clears it, and output is always zeroed.
final class ProbeTests {
    let probe: OpaquePointer

    init() throws {
        probe = try #require(domine_probe_create())
    }

    deinit { domine_probe_destroy(probe) }

    @discardableResult
    private func run(_ input: TestBufferList?, _ output: TestBufferList? = nil,
                     clientData: Bool = true) -> OSStatus {
        var now = AudioTimeStamp(), inTime = AudioTimeStamp(), outTime = AudioTimeStamp()
        let empty = TestBufferList(channelsPerBuffer: [1], frames: 0)
        return domine_probe_ioproc(
            0, &now, (input ?? empty).pointer, &inTime, (output ?? empty).pointer, &outTime,
            clientData ? UnsafeMutableRawPointer(probe) : nil)
    }

    @Test func startsClear() {
        #expect(domine_probe_heard(probe) == 0)
    }

    @Test func silenceIsNotHeard() {
        #expect(run(TestBufferList(channelsPerBuffer: [2], frames: 8, fill: 0)) == 0)
        #expect(domine_probe_heard(probe) == 0)
    }

    @Test func oneNonZeroSampleIsHeard() {
        let input = TestBufferList(channelsPerBuffer: [2], frames: 8, fill: 0)
        var right = zeros(8)
        right[7] = 1e-6
        input.setChannel(buffer: 0, channel: 1, right)
        run(input)
        #expect(domine_probe_heard(probe) == 1)
    }

    @Test func scansEveryBuffer() {
        let input = TestBufferList(channelsPerBuffer: [1, 1], frames: 4, fill: 0)
        input.setChannel(buffer: 1, channel: 0, [0, 0, -0.5, 0])
        run(input)
        #expect(domine_probe_heard(probe) == 1)
    }

    @Test func staysSetUntilReset() {
        run(TestBufferList(channelsPerBuffer: [2], frames: 4, fill: 0.25))
        run(TestBufferList(channelsPerBuffer: [2], frames: 4, fill: 0))
        #expect(domine_probe_heard(probe) == 1)
        domine_probe_reset(probe)
        #expect(domine_probe_heard(probe) == 0)
    }

    @Test func zeroesOutput() {
        let output = TestBufferList(channelsPerBuffer: [2, 1], frames: 4, fill: 0.7)
        run(TestBufferList(channelsPerBuffer: [2], frames: 4, fill: 0.3), output)
        #expect(output.channel(0) == zeros(4))
        #expect(output.channel(1) == zeros(4))
        #expect(output.channel(2) == zeros(4))
    }

    @Test func nilClientDataOnlyZeroesOutput() {
        let output = TestBufferList(channelsPerBuffer: [2], frames: 4, fill: 0.7)
        #expect(run(TestBufferList(channelsPerBuffer: [2], frames: 4, fill: 0.3), output, clientData: false) == 0)
        #expect(output.channel(0) == zeros(4))
        #expect(domine_probe_heard(probe) == 0)
    }

    @Test func destroyAcceptsNull() {
        domine_probe_destroy(nil)
    }
}
