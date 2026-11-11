# Volume and control surfaces review (read-only)

1. State/AppModel.swift:357 (setRoutingMode) + AppModel.swift:489-494
   Scenario: Stereo master at +6 dB (1.6), switch to Surround. maxMasterVolume is 1 there, so updatePairSettings clamps masterVolume to 1, and updatePairSettings persists that to the pair's saved record (store.setPairSettings). Back in Stereo the boost is gone, 100% instead of +6 dB. Same loss for Single with its own record when crossing modes.
   Fix: clamp only the effective value (engine.boost already does min(master, max)), or keep a separate unclamped saved master for Stereo/Single; do not persist the clamp.
   Confidence: high.

2. State/AppModel.swift:357, AppModel+Advanced.swift:30 (only two places that clamp master to maxMasterVolume)
   Scenario: max volume set to 100% or 150% in Advanced, pair record saved earlier with master 2.0. Loading a pair (launch, speaker reassignment, room select, Single speaker change) does not clamp. Menu and main label show "+10 dB" and the slider is out of range, while engine.boost uses min(master, max), so the label disagrees with what plays. Volume keys then step from 2.0 down (apply clamps to max, so first key press jumps 200% to max, then continues).
   Fix: clamp in loadPairSettings and wherever pairSettings is reassigned, or clamp inside updatePairSettings/at the pairSettings getter used for display.
   Confidence: medium-high.

3. State/AppModel+VirtualOutput.swift:125-128 (onVolume) and :132,:143
   Scenario: Boost at 150% with the virtual output as default. The virtual device is mirrored at 1.0, so volume-up keys do nothing (no change event) and the boost can only be changed by the Domine slider. Pressing volume-down moves the device to 0.9375 and master jumps from 150% to 94% in one press, instead of one step.
   Fix: when master > 1 and a system volume down arrives, set master = max(master - 1/16, ...) rather than the device value, then mirror 1.0 back; or mirror the device at min(master,1) but treat a down event at master>1 as a relative step. Up cannot be caught without a driver range above 1; document it.
   Confidence: high that the jump occurs; fix is a design decision.

4. UI/VolumeHUD.swift:12-14, 32 and AppModel+VolumeKeys.swift:65
   Scenario: Key tap fallback with master in the boost range: HUD gets min(volume,1), so all 16 bars are lit and VoiceOver says "100 percent" for every press from 100% to 200%. No feedback that keys are changing the boost.
   Fix: pass the boost to the HUD (for example a "+N dB" caption using VolumeText.label), or stop the HUD bars at 100% but show the label.
   Confidence: high (cosmetic).

5. State/AppModel+AppAudio.swift:4-10, 33 and UI/Menu/StatusMenuAppRow.swift:25-31
   Scenario: App excluded by a non-Always rule (isExcluded in the menu is true only for mode .always). The menu shows the Exclude box unchecked and an enabled 0 to 200% slider, but applyAppVolumesToEngine drops the app (engine.excludedProcesses contains it), so the slider does nothing. Likewise at the tap limit (appVolumeLimitReached) the slider stays enabled and silently does nothing beyond the footnote.
   Fix: set isExcluded for any active exclusion (or disable the slider when the process is in engine.excludedProcesses), and disable sliders for apps with no tap slot.
   Confidence: medium.

6. State/AppModel+AppAudio.swift:48-61 (setAppExcluded)
   Scenario: Unchecking Exclude in the menu calls exclusionsSettings.remove(bundleIDs:), deleting an item the user created with another mode (for example "while running" with other options) and checking it overwrites that item's mode with .always. Menu toggle changes the user's saved rule semantics.
   Fix: keep the item and track a menu-level override, or only touch items whose mode is .always.
   Confidence: medium-low.

Checked and found fine: volume key step and clamp to maxMasterVolume (VolumeKeyEvent.apply), HUD honours showsVolumeHUD in the tap path (the system HUD covers the virtual-output path), mute mirrors to virtual output, menu slider range max(1, maxVolume), menu state rebuilt from observable model each read, SpeakerVolumeLink rise limits and read-back quantization match SPEC 4a.
