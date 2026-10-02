import CoreAudio
import DomineDSP
import Testing

struct RecorderTests {
    func feed(_ r: OpaquePointer, _ input: TestBufferList) {
        var now = AudioTimeStamp(), t = AudioTimeStamp(), o = AudioTimeStamp()
        _ = domine_recorder_ioproc(0, &now, input.pointer, &t, nil, &o, UnsafeMutableRawPointer(r))
    }

    func contents(_ r: OpaquePointer) -> [Float] {
        var out = [Float](repeating: -1, count: 64)
        let n = domine_recorder_copy(r, &out, 64)
        return Array(out.prefix(Int(n)))
    }

    @Test func appendsAcrossCalls() {
        let r = domine_recorder_create(16)!
        defer { domine_recorder_destroy(r) }
        feed(r, .interleaved(left: [1, 2, 3], right: [9, 9, 9]))
        feed(r, .interleaved(left: [4, 5], right: [9, 9]))
        #expect(domine_recorder_frames_written(r) == 5)
        #expect(contents(r) == [1, 2, 3, 4, 5])
    }

    @Test func nonInterleavedTakesFirstBuffer() {
        let r = domine_recorder_create(16)!
        defer { domine_recorder_destroy(r) }
        feed(r, .deinterleaved(left: [1, 2], right: [7, 7]))
        #expect(contents(r) == [1, 2])
    }

    @Test func monoInput() {
        let r = domine_recorder_create(16)!
        defer { domine_recorder_destroy(r) }
        let list = TestBufferList(channelsPerBuffer: [1], frames: 3, fill: 0)
        list.setChannel(buffer: 0, channel: 0, [0.5, 0.25, 0.125])
        feed(r, list)
        #expect(contents(r) == [0.5, 0.25, 0.125])
    }

    @Test func stopsWhenFullAndResets() {
        let r = domine_recorder_create(4)!
        defer { domine_recorder_destroy(r) }
        feed(r, .interleaved(left: [1, 2, 3], right: [0, 0, 0]))
        feed(r, .interleaved(left: [4, 5, 6], right: [0, 0, 0]))
        feed(r, .interleaved(left: [7], right: [0]))
        #expect(domine_recorder_frames_written(r) == 4)
        #expect(contents(r) == [1, 2, 3, 4])
        domine_recorder_reset(r)
        #expect(domine_recorder_frames_written(r) == 0)
        feed(r, .interleaved(left: [8], right: [0]))
        #expect(contents(r) == [8])
    }
}
