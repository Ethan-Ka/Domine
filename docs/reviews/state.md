# State review (Sources/Domine/State), most severe first

1. Status menu "Sound" preset edits the Stereo pair's effects while in Surround
   - AppModel+Background.swift:68 (matched from pairSettings.effects), :98-100 (applyPreset), AppModel.swift setEffects/applyPreset -> updatePairSettings; Surround effects come only from surroundSettings (AppModel.swift applySurroundSettingsToEngine, AppModel+Sound.swift routes the Sound sheet to setSurroundEffects but the menu does not).
   - Scenario: Surround mode, open the menu bar item, pick Sound > Bass Boost. Nothing changes audibly, the picker shows a preset the speakers are not playing, and the stored pair record for the front two speakers is silently changed (heard next time you go back to Stereo).
   - Fix: in applyStatusMenuEdit and statusMenuState route through the same surroundSoundUID logic as soundState/setSoundEffects (read/write surroundEffects(first)); or hide the picker in Surround.
   - Confidence: high.

2. Speakers without settable hardware volume get master gain > 1 AND the boost
   - AppModel.swift kernelVolume(for:) fallback branch (~line 600): returns `master * offsetGain` with no cap at 1; applyPairSettingsToEngine also sets engine.boost = boostGain(master).
   - Scenario: Stereo or Single, speaker with no settable volume, master 150%. leftGain/rightGain = 1.5 and boost = +5 dB, so about +8.5 dB instead of +5 dB (up to +6 dB digital plus +10 dB = about +16 dB at 200%). Violates "Domine never adds digital gain" in SpeakerVolume doc; the limiter hides clipping but loudness is far above the slider.
   - Fix: use `min(master, 1)` in the no-hardware branch.
   - Confidence: high (code), medium on audible impact.

3. Visiting Surround permanently drops a Stereo boost
   - AppModel.swift:357 (setRoutingMode clamps pairSettings.masterVolume to maxMasterVolume = 1 in surround via updatePairSettings), which saves to the shared pair record (updatePairSettings non-single branch).
   - Scenario: Stereo at 180%, switch to Surround and back: Stereo now at 100%.
   - Fix: keep a separate surround master or clamp only for display/engine (min(...)) without persisting.
   - Confidence: high.

4. Stored master volume above the current maximum is never clamped on load
   - Clamp exists only at AppModel.swift:357 (mode switch) and AppModel+Advanced.swift:30 (changing the slider). Not on init (AppModel.swift ~line 188), setSpeakers (~line 297), or selectRoom.
   - Scenario: pair saved at 190%, Maximum volume later set to 100% (or a different pair with a higher saved value is chosen, or app relaunches after lowering it from another run); model keeps 1.9, sliders (range 0...maxVolume) show pinned at the end, menu/HUD percent and virtual-output mirror disagree, kernelVolume (item 2) uses the unclamped value. The engine boost is clamped, so only the display and gains disagree.
   - Fix: a helper that clamps pairSettings.masterVolume whenever pairSettings is loaded (loadPairSettings caller sites) or in updatePairSettings.
   - Confidence: high on missing clamp, medium on user impact.

5. Wake-from-sleep resume waits for every Surround speaker, but routing needs only two
   - AppModel+Sleep.swift systemDidWake loop on `allSpeakersPresent` (AppModel.swift: all uids present and count >= 2) vs surroundRouteSpeakers which routes with >= 2 connected.
   - Scenario: 4-speaker set with one speaker off or out of range, routing on, Mac sleeps. After wake it waits 60 s, gives up, and never restarts (resumeAfterWake stays true until next wake). Same all-or-nothing rule in autoStartIfSpeakersConnected, so a set with one permanently missing speaker never auto-starts.
   - Fix: wait on `surroundRouteSpeakers != nil` (or the connected count) for Surround.
   - Confidence: medium-high.

6. "User turned routing off" flag is cleared by any catalog change while a speaker is absent
   - AppModel.swift autoStartIfSpeakersConnected: `if !present { ... userTurnedRoutingOff = false }` runs on every catalog sync, not only on a connected -> missing edge.
   - Scenario: one of the pair is off, user turns Domine off, then any unrelated output appears (AirPods connect). Flag resets; when the missing speaker later connects, Domine auto-starts although the user switched it off and the speaker never "disconnected and came back" as SPEC 6a describes.
   - Fix: reset only when `speakersWerePresent` was true and present is now false.
   - Confidence: medium.

7. Advanced clock speaker change during .starting is lost
   - AppModel+Advanced.swift:13-14: `if !engine.state.isRouting { engine.clockSpeakerUID = ... }` also runs in .starting; the follow-up engine.setClockSpeaker (Engine.swift:1060) then returns at `guard uid != clockSpeakerUID` and never rebuilds.
   - Scenario: change Timing reference in the few hundred ms while the aggregate is building with the old clock; route ends .running on the old clock until the next rebuild.
   - Fix: gate on `!engine.state.isActive` in applyAdvancedSettings so setClockSpeaker owns the update while starting/running (and have setClockSpeaker rebuild once state reaches running).
   - Confidence: low-medium (narrow race).

8. Deleting a Surround field preset leaves rooms pointing at it
   - AppModel+Surround.swift deleteSurroundFieldPreset does not clear Room.surroundPreset (rename does update rooms). selectRoom then silently skips the preset (AppModel+Rooms.swift), room keeps the set's last field values.
   - Fix: nil out surroundPreset in matching rooms on delete and save rooms.
   - Confidence: high, low severity.

9. Emptying the Surround set is not persisted
   - saveSurroundSettings (AppModel+Surround.swift) returns early for empty speakers, so lastSurroundUIDs and the old record stay; relaunch brings the removed speakers back.
   - Fix: write lastSurroundUIDs = [] (and loadSurroundSettings already treats empty as none).
   - Confidence: medium, low severity.

Checked and fine: Single/Stereo/Surround record keys (single.<uid>, pair.<sorted>, surround.<sorted>) and mode-cross reload; pair flip on swapped order; Single field filter; Advanced settings all applied live (keep-alive, calibration, reconnect, HUD, offset range, max volume) and clamped identically in model and UI ranges; calibration undo is cleared by hand edits in both Stereo (setDelayMs/setBalance) and Surround (TuningSheet discardUndo), Reset, sheet close, and open; rooms restore mode, pair, rears, surround set and preset. The nested didSet in advancedSettingsDidChange only re-enters when a value is out of range, which the UI never produces (harmless double apply). Doc comment on Settings.startWhenBothConnect says "Off by default" but default is true (comment only).
