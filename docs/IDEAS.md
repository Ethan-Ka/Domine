# Ideas and gaps

Collected 2026-11-11 from read-only reviews of the UI, the settings sheets, and the hard-coded values in the code. Nothing here is built yet. Ranked by user value inside each section.

## Top five

1. Show sync state on the stage: which speaker is the timing reference and how much each one is delayed.
2. Show connection health per speaker (dropouts, poor connection) instead of the same line for every state.
3. Explain every Sound and Sync & Balance control in one line, with units and a readout on every slider.
4. Make the menu bar menu follow the mode. It still assumes a left and right speaker in Single and Surround.
5. Expose the hard-coded tuning values as settings behind an Advanced section (EQ bands, night mode strength, keep-alive tone, clock speaker, calibration length).

## Visual gaps

| # | Gap | Suggestion | Where |
| --- | --- | --- | --- |
| 1 | No per-speaker sync readout. The user cannot see which speaker is slowest or what the delay does. | Card detail line "Timing reference" on one card and "Delayed 42 ms" on the others; a small "+4 ms" on the delayed connector. | `Main/SpeakerCardState.swift`, `SpeakerCard.swift`, `StageView.swift` |
| 2 | No dropout or glitch indicator. A stuttering speaker looks healthy. | A `health` state per card (ok, dropouts) that drives the connector with a warning symbol and "Dropped out 3 times". The data already exists in the diagnostics dropout tracker. | `SpeakerCardState.swift`, `SpeakerConnection.swift`, `StageBanner.swift` |
| 3 | The stage banner is one red string, used only for mono fallback. | Banner model with severity (info, warning, error), an optional action (Reconnect, Open Settings), and dismiss. Use yellow for warnings. | `StageBanner.swift`, `MainWindowState.swift` |
| 4 | Low battery is small text only. No charging state, nothing in the menu bar. | Battery in the menu speaker rows, a charging symbol, and a low battery banner at 15% or less. | `SpeakerCard.swift`, `Menu/StatusMenuSpeakerRow.swift` |
| 5 | The menu bar menu is hard-wired to left and right. Swap shows in Single and Surround. | Data-driven speaker list, current mode with a picker, Swap only in Stereo, text status next to the dot. | `Menu/StatusMenu.swift`, `StatusMenuState.swift` |
| 6 | The menu row's identify tone is only discoverable through a tooltip. | A speaker symbol on the row and a playing state while the tone runs. | `Menu/StatusMenu.swift`, `StatusMenuSpeakerRow.swift` |
| 7 | Thin empty and off states. Cards just look idle when Domine is off. | Dimmed stage with a Turn On button when off, "Nothing playing" when every level is zero, a progress indicator and failure line on Reconnect. | `StageView.swift`, `MainContentView.swift` |
| 8 | No animation on state changes. Cards, connectors and the banner snap. Meters have no peak hold. | Animate connection and banner changes, add a peak hold segment to the meter, respect Reduce Motion for orbit and demo. | `SpeakerCard.swift`, `StageBanner.swift`, `LevelMeter.swift` |
| 9 | Some visuals mislead: no clip indicator, the same connector for "connected" and "playing", the mono fallback tag in accent blue next to a red fault. | Clip latch, dim the connector at zero level, neutral tag colour for mono fallback. | `LevelMeter.swift`, `StageView.swift`, `SpeakerCard.swift` |
| 10 | Fixed card size. Large surround sets overlap and the bottom bar can clip. | Card size from stage size with a compact card below a threshold; wrap the surround bottom bar. | `DomineApp.swift`, `StageLayout.swift`, `MainBottomBar.swift` |
| 11 | Surround stage shows no distances or ring labels. | Distance caption while dragging, ring labels (1 m, 2 m), "FRONT" label in every mode. | `StageView.swift`, `SurroundControls.swift` |
| 12 | Mute, boost and test tones are hard to see. | A "Muted" label on the stage, a tinted boost region on the volume slider, Test L and Test R that read "Stop" while playing. | `MainToolbarControls.swift`, `MainBottomBar.swift`, `VolumeText.swift` |

## Settings clarity

| # | Problem | Fix | Where |
| --- | --- | --- | --- |
| 1 | Bass, Compressor and Crossfeed have no explanation, and their sliders have no readout or units. | Captions: Compressor "Makes quiet parts louder and loud parts softer." Crossfeed "Mixes some of each side into the other so the sound feels less split." Bass "Boosts low frequencies." A % readout on each slider. | `Sound/SoundSheet.swift` |
| 2 | EQ band labels have no units and there is no visible dB readout while dragging. | "80 Hz, 250 Hz, 1 kHz, 4 kHz, 10 kHz", a live "+3 dB" readout, a 0 dB center line. | `SoundSheet.swift`, `SoundState.swift`, `VerticalGainSlider.swift` |
| 3 | "Same sound on both speakers" silently pins crossfeed to 100% and greys it out. | Caption "Set to 100% while both speakers play the same sound." | `SoundSheet.swift` |
| 4 | "Link speakers" and Reset change scope without saying so. | Rename to "Same effects on all speakers"; when unlinked show "Editing: Front Left"; Reset reads "Reset This Speaker" or "Reset All". | `SoundSheet.swift` |
| 5 | Surround "Mono" sits next to Link and explains itself only in a tooltip. | Own row, label "Mix left and right together", visible caption. | `SoundSheet.swift` |
| 6 | Delay offset has no guidance. Arrow-key nudges are undiscoverable. | Caption "If the sound reaches you from one speaker first, delay that speaker." Readout "In sync" at 0. Hint "Arrow keys nudge 1 ms, Shift for 5 ms." | `Tuning/TuningSheet.swift`, `TuningState.swift` |
| 7 | Auto-calibrate explains itself only after it starts, and its result cannot be undone. | Caption before the run ("Uses the Mac's microphone to line up the speakers. Put the Mac where you sit."), visible reason when unavailable, "Undo Calibration" after a run. | `TuningSheet.swift` |
| 8 | Balance and Speaker volume both live under LEVEL with no explanation of the difference. | Rename the stepper section "Match speaker loudness" with a caption; in Surround call the trim "Mix level". | `TuningSheet.swift`, `SpeakerVolumeRow.swift` |
| 9 | Six ungrouped General checkboxes with no captions. | Group under Startup, Speakers and Quitting, each with a one-line caption. | `Settings/GeneralSettingsView.swift`, `SetupSection.swift` |
| 10 | Related settings are scattered. Accessibility status shows twice. | Merge Accessibility into the Volume keys row; consider one Tune window with Timing, Levels and Sound tabs. | `GeneralSettingsView.swift`, `TuningSheet.swift` |
| 11 | Exclusions never says what exclusion means and has no empty state. | Header "Apps that skip your speakers", caption, "Click + to add an app" empty state. | `Settings/ExclusionsView.swift`, `ExclusionRow.swift` |
| 12 | Welcome and Assign use jargon and assume JBL. | "Turn off the speakers' own stereo pairing", "Let Domine capture your Mac's audio", "Play tone to identify". | `Welcome/WelcomeStep.swift`, `Assign/AssignSheet.swift` |

## Customizability

| # | Missing | Why | Where it would live |
| --- | --- | --- | --- |
| 1 | Per-speaker role and crossover (sub, satellite, full range). | Mixed speakers need high-pass and low-pass, and a real sub needs an LFE role. | `SurroundSpeaker.swift`, Sync & Balance |
| 2 | EQ band count, types and frequencies. | Fixed at 5 bands (80 Hz to 10 kHz). Other speakers need other shelf points or a notch. | `PairSettings+Effects.swift`, Sound sheet |
| 3 | Night mode strength. | Fixed at 6:1, +6 dB, about -30 dB threshold. | `PairSettings+Effects.swift`, Sound sheet |
| 4 | Keep-alive tone settings. | Fixed at 2 s idle, 15 Hz, -60 dBFS. Tuned for the Grip; other speakers may sleep anyway or hum. | Advanced under "Keep speakers from turning off" |
| 5 | Choice of clock speaker. | Hard-coded to the left speaker (`AggregateBuilder.clock`). A flaky clock speaker hurts sync for every speaker. | General or Advanced settings |
| 6 | Keyboard shortcuts and volume step size. | Only one shortcut exists. Steps are fixed at 1/16 and 1/64. | New Shortcuts tab |
| 7 | Automatic room switching and auto-start rules. | Rooms are manual. Rules like "this speaker set loads room X" or "night mode after 22:00". | New Automation tab, `Room.swift` |
| 8 | Volume ceiling and boost limit. | Boost fixed at +10 dB, offsets at plus or minus 12 dB. Some want a safety cap. | General, read by `PairSettings.sanitize()` |
| 9 | Calibration length, repeats and chirp level. | Fixed at 5.5 s, 3 retries. Noisy rooms and quiet speakers need more. | Advanced in the calibration area |
| 10 | Delay nudge step sizes, including sub-millisecond. | Fixed at 1 and 5 ms. | Sync & Balance |
| 11 | Meter style (peak hold, RMS, hide). | 16 segments and 20 dB/s decay are fixed. | General, Display group |
| 12 | Menu bar icon contents. | Static icon. Could show volume, mode, room, or a dropped speaker. | General, Menu bar group |
| 13 | Reconnect timing and the volume HUD. | Reconnect 5 s, 30 s, give up at 10 min. HUD cannot be turned off. | General, Advanced |
| 14 | Speaker and per-app tap limits. | 4 Bluetooth speakers and 7 per-app volumes, silently capped. | Raise, and warn in the per-app list |
| 15 | Surround presets (movie, music) separate from rooms. | Width, surround level and spatial amount have fixed defaults. | Named presets inside a Room |

## Suspected issues not fixed in the bug review

- Surround set changes have the same auto-start problem that mode switches had (`AppModel+Surround.swift`).
- Single mode saves settings under the Stereo pair's key, and not at all when no right speaker is set.
- `selectSurroundSet` can load a saved record whose speaker order differs from the requested order.
- Volume link: the learned hardware step survives `detach()`, so a coarser speaker attached later could read as a button press.
- The compressor never sanitises its parameters; a NaN would stick until it is turned off and on.
- No denormal protection in the bass, spatial and EQ filter states (CPU cost on Intel Macs during silence).
- The surround kernel's test tone or calibration index can be below 16 but past the speaker count, which silences every speaker.
- Saved rooms decode strictly: one corrupt room drops all of them.
