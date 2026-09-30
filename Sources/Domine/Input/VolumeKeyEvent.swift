import CoreGraphics

/// A decoded hardware volume key press (SPEC 4b).
///
/// Built from the `data1` field of an `NX_SYSDEFINED` event with subtype 8
/// (`NX_SUBTYPE_AUX_CONTROL_BUTTONS`). Decoding and applying are pure so they
/// can be tested without a real event tap.
struct VolumeKeyEvent: Equatable, Sendable {
    enum Key: Equatable, Sendable {
        case volumeUp
        case volumeDown
        case mute
    }

    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`.
    static let auxControlButtonsSubtype = 8
    /// `NX_KEYTYPE_SOUND_UP`.
    static let soundUpKeyCode = 0
    /// `NX_KEYTYPE_SOUND_DOWN`.
    static let soundDownKeyCode = 1
    /// `NX_KEYTYPE_MUTE`.
    static let muteKeyCode = 7
    /// `NX_KEYDOWN` as encoded in the key state byte of `data1`.
    static let keyDownState = 0xA
    /// `NX_KEYUP` as encoded in the key state byte of `data1`.
    static let keyUpState = 0xB

    /// Normal step: 1/16 of full scale, same as macOS.
    static let normalStep: Float = 1.0 / 16.0
    /// Fine step with Option+Shift held: 1/64 of full scale, same as macOS.
    static let fineStep: Float = 1.0 / 64.0

    let key: Key
    /// True for key down and auto-repeat. Key up events are decoded so the tap
    /// can swallow them, but they never change the volume.
    let isKeyDown: Bool
    let isRepeat: Bool
    /// Volume change per press for up and down, as a fraction of full scale.
    let step: Float

    /// Decodes an `NX_SYSDEFINED` event. Returns nil for any subtype other
    /// than 8, for key codes other than sound up, sound down, and mute, and
    /// for key states other than down or up.
    static func decode(subtype: Int, data1: Int, flags: CGEventFlags) -> VolumeKeyEvent? {
        guard subtype == auxControlButtonsSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyState = (data1 & 0xFF00) >> 8
        let isRepeat = (data1 & 0x1) != 0

        let key: Key
        switch keyCode {
        case soundUpKeyCode: key = .volumeUp
        case soundDownKeyCode: key = .volumeDown
        case muteKeyCode: key = .mute
        default: return nil
        }

        let isKeyDown: Bool
        switch keyState {
        case keyDownState: isKeyDown = true
        case keyUpState: isKeyDown = false
        default: return nil
        }

        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        return VolumeKeyEvent(
            key: key,
            isKeyDown: isKeyDown,
            isRepeat: isRepeat,
            step: fine ? fineStep : normalStep)
    }

    /// Returns the new master volume and mute state after this key event.
    /// Volume is clamped to 0...1. Mute toggles. Volume up while muted
    /// unmutes. Key up events, and mute auto-repeats, return the inputs
    /// unchanged.
    func apply(to volume: Float, muted: Bool) -> (Float, Bool) {
        guard isKeyDown else { return (volume, muted) }
        switch key {
        case .volumeUp:
            return (min(1, max(0, volume + step)), false)
        case .volumeDown:
            return (min(1, max(0, volume - step)), muted)
        case .mute:
            // A held mute key would otherwise flicker on every repeat.
            return isRepeat ? (volume, muted) : (volume, !muted)
        }
    }
}
