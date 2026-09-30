import CoreGraphics
import Testing
@testable import Domine

struct VolumeKeyTests {
    /// Builds data1 the way the system packs it: key code in the high 16 bits,
    /// key state in bits 8 to 15, repeat flag in bit 0.
    static func data1(keyCode: Int, state: Int, isRepeat: Bool = false) -> Int {
        (keyCode << 16) | (state << 8) | (isRepeat ? 1 : 0)
    }

    static func down(_ keyCode: Int, flags: CGEventFlags = []) -> VolumeKeyEvent? {
        VolumeKeyEvent.decode(subtype: 8, data1: data1(keyCode: keyCode, state: 0xA), flags: flags)
    }

    static func event(_ key: VolumeKeyEvent.Key, isKeyDown: Bool = true,
                      isRepeat: Bool = false, step: Float = 1.0 / 16.0) -> VolumeKeyEvent {
        VolumeKeyEvent(key: key, isKeyDown: isKeyDown, isRepeat: isRepeat, step: step)
    }

    // MARK: Decode

    @Test func decodesVolumeUpDown() {
        #expect(Self.down(0) == Self.event(.volumeUp))
    }

    @Test func decodesVolumeDownDown() {
        #expect(Self.down(1) == Self.event(.volumeDown))
    }

    @Test func decodesMuteDown() {
        #expect(Self.down(7) == Self.event(.mute))
    }

    @Test func decodesRawSystemValue() {
        // Packed values as the system sends them: code 0 down is 0x00000A00,
        // code 7 down is 0x00070A00.
        let decoded = VolumeKeyEvent.decode(subtype: 8, data1: 0x0000_0A00, flags: [])
        #expect(decoded == Self.event(.volumeUp))
        let mute = VolumeKeyEvent.decode(subtype: 8, data1: 0x0007_0A00, flags: [])
        #expect(mute == Self.event(.mute))
    }

    @Test func decodesKeyUp() {
        let decoded = VolumeKeyEvent.decode(
            subtype: 8, data1: Self.data1(keyCode: 1, state: 0xB), flags: [])
        #expect(decoded == Self.event(.volumeDown, isKeyDown: false))
    }

    @Test func decodesRepeat() {
        let decoded = VolumeKeyEvent.decode(
            subtype: 8, data1: Self.data1(keyCode: 0, state: 0xA, isRepeat: true), flags: [])
        #expect(decoded == Self.event(.volumeUp, isRepeat: true))
    }

    @Test func ignoresUnrelatedKeyCodes() {
        // Brightness up (2), brightness down (3), play (16), next (17), previous (18).
        for code in [2, 3, 4, 5, 6, 8, 16, 17, 18, 19, 20] {
            #expect(Self.down(code) == nil, "key code \(code)")
        }
    }

    @Test func ignoresOtherSubtypes() {
        let data1 = Self.data1(keyCode: 0, state: 0xA)
        for subtype in [0, 1, 7, 9, 14] {
            #expect(VolumeKeyEvent.decode(subtype: subtype, data1: data1, flags: []) == nil)
        }
    }

    @Test func ignoresUnknownKeyState() {
        let decoded = VolumeKeyEvent.decode(
            subtype: 8, data1: Self.data1(keyCode: 0, state: 0x0), flags: [])
        #expect(decoded == nil)
    }

    // MARK: Step size

    @Test func normalStepIsOneSixteenth() {
        #expect(Self.down(0)?.step == 0.0625)
    }

    @Test func optionShiftStepIsOneSixtyFourth() {
        #expect(Self.down(0, flags: [.maskAlternate, .maskShift])?.step == 0.015625)
        #expect(Self.down(1, flags: [.maskAlternate, .maskShift])?.step == 0.015625)
    }

    @Test func optionAloneIsNormalStep() {
        #expect(Self.down(0, flags: .maskAlternate)?.step == 0.0625)
    }

    @Test func shiftAloneIsNormalStep() {
        #expect(Self.down(0, flags: .maskShift)?.step == 0.0625)
    }

    @Test func otherModifiersDoNotChangeStep() {
        #expect(Self.down(0, flags: [.maskCommand, .maskControl])?.step == 0.0625)
        #expect(Self.down(0, flags: [.maskAlternate, .maskShift, .maskCommand])?.step == 0.015625)
    }

    // MARK: Apply

    @Test func upAddsStep() {
        let (v, m) = Self.event(.volumeUp).apply(to: 0.5, muted: false)
        #expect(v == 0.5625)
        #expect(m == false)
    }

    @Test func downSubtractsStep() {
        let (v, m) = Self.event(.volumeDown).apply(to: 0.5, muted: false)
        #expect(v == 0.4375)
        #expect(m == false)
    }

    @Test func fineStepApplies() {
        let (v, _) = Self.event(.volumeUp, step: 1.0 / 64.0).apply(to: 0.5, muted: false)
        #expect(v == 0.515625)
    }

    @Test func upClampsAtOne() {
        #expect(Self.event(.volumeUp).apply(to: 0.97, muted: false) == (1.0, false))
        #expect(Self.event(.volumeUp).apply(to: 1.0, muted: false) == (1.0, false))
    }

    @Test func downClampsAtZero() {
        #expect(Self.event(.volumeDown).apply(to: 0.03, muted: false) == (0.0, false))
        #expect(Self.event(.volumeDown).apply(to: 0.0, muted: false) == (0.0, false))
    }

    @Test func sixteenStepsGoFromZeroToOne() {
        var volume: Float = 0
        var muted = false
        for _ in 0..<16 {
            (volume, muted) = Self.event(.volumeUp).apply(to: volume, muted: muted)
        }
        #expect(volume == 1.0)
    }

    @Test func muteToggles() {
        #expect(Self.event(.mute).apply(to: 0.5, muted: false) == (0.5, true))
        #expect(Self.event(.mute).apply(to: 0.5, muted: true) == (0.5, false))
    }

    @Test func muteRepeatDoesNotToggle() {
        #expect(Self.event(.mute, isRepeat: true).apply(to: 0.5, muted: false) == (0.5, false))
    }

    @Test func upWhileMutedUnmutes() {
        #expect(Self.event(.volumeUp).apply(to: 0.5, muted: true) == (0.5625, false))
    }

    @Test func downWhileMutedStaysMuted() {
        #expect(Self.event(.volumeDown).apply(to: 0.5, muted: true) == (0.4375, true))
    }

    @Test func repeatChangesVolume() {
        #expect(Self.event(.volumeUp, isRepeat: true).apply(to: 0.5, muted: false) == (0.5625, false))
    }

    @Test func keyUpChangesNothing() {
        #expect(Self.event(.volumeUp, isKeyDown: false).apply(to: 0.5, muted: true) == (0.5, true))
        #expect(Self.event(.volumeDown, isKeyDown: false).apply(to: 0.5, muted: false) == (0.5, false))
        #expect(Self.event(.mute, isKeyDown: false).apply(to: 0.5, muted: false) == (0.5, false))
    }
}
