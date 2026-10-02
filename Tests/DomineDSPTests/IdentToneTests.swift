import CoreAudio
import Foundation
import Testing
import DomineDSP

struct IdentToneTests {
    static let rate = 8000.0

    private func run(_ tone: OpaquePointer?, _ out: TestBufferList) {
        var now = AudioTimeStamp(), inTime = AudioTimeStamp(), outTime = AudioTimeStamp()
        let empty = TestBufferList(channelsPerBuffer: [1], frames: 0)
        _ = domine_tone_ioproc(0, &now, empty.pointer, &inTime, out.pointer, &outTime,
                               tone.map { UnsafeMutableRawPointer($0) })
    }

    private func expected(frame: Int, total: Int, fade: Int) -> Float {
        let s = Float(ChimeReference.sample(Double(frame) / Self.rate))
        let env: Float
        if frame < fade { env = Float(frame) / Float(fade) }
        else if total - frame <= fade { env = Float(total - frame - 1) / Float(fade) }
        else { env = 1 }
        return s * env
    }

    @Test func writesSameSampleToEveryChannelOfEveryBuffer() {
        let tone = domine_tone_create(Self.rate, 0.1)  // 800 frames, 320-frame fades
        defer { domine_tone_destroy(tone) }
        let out = TestBufferList(channelsPerBuffer: [2, 1], frames: 200)
        run(tone, out)
        for frame in 0..<200 {
            let want = expected(frame: frame, total: 800, fade: 320)
            #expect(abs(out.samples(buffer: 0, channel: 0)[frame] - want) < 1e-6)
            #expect(abs(out.samples(buffer: 0, channel: 1)[frame] - want) < 1e-6)
            #expect(abs(out.samples(buffer: 1, channel: 0)[frame] - want) < 1e-6)
        }
    }

    @Test func continuesAcrossCallsThenGoesSilentAndFinishes() {
        let tone = domine_tone_create(Self.rate, 0.1)
        defer { domine_tone_destroy(tone) }
        var frame = 0
        for _ in 0..<4 {
            let out = TestBufferList(channelsPerBuffer: [2], frames: 256)
            run(tone, out)
            for i in 0..<256 {
                let want: Float = frame < 800 ? expected(frame: frame, total: 800, fade: 320) : 0
                #expect(abs(out.samples(buffer: 0, channel: 0)[i] - want) < 1e-6)
                frame += 1
            }
        }
        #expect(domine_tone_finished(tone!) == 1)
    }

    @Test func notFinishedPartWay() {
        let tone = domine_tone_create(Self.rate, 0.1)
        defer { domine_tone_destroy(tone) }
        run(tone, TestBufferList(channelsPerBuffer: [2], frames: 100))
        #expect(domine_tone_finished(tone!) == 0)
    }

    @Test func fadeEndsAtZero() {
        let tone = domine_tone_create(Self.rate, 0.1)
        defer { domine_tone_destroy(tone) }
        let out = TestBufferList(channelsPerBuffer: [1], frames: 800)
        run(tone, out)
        #expect(out.samples(buffer: 0, channel: 0)[0] == 0)
        #expect(out.samples(buffer: 0, channel: 0)[799] == 0)
    }

    @Test func nullClientDataZeroesOutput() {
        let out = TestBufferList(channelsPerBuffer: [2], frames: 16)
        run(nil, out)
        for i in 0..<16 { #expect(out.samples(buffer: 0, channel: 0)[i] == 0) }
    }

    @Test func rejectsNonPositiveArguments() {
        #expect(domine_tone_create(0, 1) == nil)
        #expect(domine_tone_create(48000, 0) == nil)
        #expect(domine_tone_create(-1, 1) == nil)
    }
}

