# Ideas and plans

Updated 2026-11-11. What is built, what is still open, and the next planned phase.

## Done (0.4.0)

Everything on the approved list is built and tested:

- **Stage:**
  - Each speaker card shows "Timing reference" or "Delayed N ms", plus dropout warnings.
  - The stage banner has warning levels and actions, and warns about low battery.
  - Off and "Nothing playing" states.
  - Animations that respect Reduce Motion.
  - Ring and distance labels, a Muted label, a boost tint on the volume slider, and Test buttons that read "Stop".
  - Cards resize with the window, and there are compact cards for large surround sets.
- **Meters:** peak hold, a clip indicator, and Display settings (style, peak hold, show meters).
- **Menu bar:**
  - It follows the mode.
  - Each speaker row shows its battery and has an identify tone.
  - A setting picks what the icon shows, and it gets a warning badge.
- **Sound sheet:**
  - EQ units and readouts, and editable bands (1 to 8, with peak, shelf and notch types).
  - Night mode strength.
  - Clear wording for linked effects, Reset and Mono.
  - Moving a slider turns its effect on.
- **Sync & Balance:**
  - A calibration caption and Undo Calibration.
  - Nudge step sizes and 0.5 ms delays.
  - Speaker roles (full range, satellite, subwoofer) with a crossover.
- **Settings:**
  - General grouped under Startup, Speakers, Quitting, Display and Menu bar.
  - Clearer Exclusions, Welcome and Assign text.
  - Setup counts speakers of any brand.
- **Advanced tab:**
  - Keep-alive tone.
  - Timing reference speaker.
  - Volume and offset limits.
  - Calibration length.
  - Reconnect timing and the volume overlay.
- **Surround:** field presets (Music, Movie, Voice, your own, or No Preset). Rooms remember the preset they were saved with.
- **Per-app volume:**
  - Up to +6 dB.
  - Helper processes update in place instead of rebuilding the audio path.
  - The menu says when all 7 slots are used.
- **Fixes:**
  - Surround auto-start, Single mode's own settings, surround order, the volume step, and saved rooms.
  - Hardening against NaN and denormals in the audio filters, and the surround index check.

## Open ideas (not approved yet)

| Idea | Why | Where |
| --- | --- | --- |
| Explain Bass, Compressor and Crossfeed in one line each, with a % readout | Jargon with no units | Sound sheet |
| Caption when "Same sound on both speakers" sets crossfeed to 100% | The slider greys out with no reason | Sound sheet |
| Delay guidance: "If the sound reaches you from one speaker first, delay that speaker." and "In sync" at 0 | Delay direction is unclear | Sync & Balance |
| Rename the level stepper to "Match speaker loudness" and the surround trim to "Mix level" | Two level controls with no explanation | Sync & Balance |
| One Tune window with Timing, Levels and Sound tabs | Related settings live in separate sheets | New window |
| Keyboard shortcuts and volume step size | Only one shortcut exists; steps are fixed | New Shortcuts tab |
| Automatic room switching and auto-start rules | Rooms are manual | New Automation tab |

## Planned: Headphones phase

Control headphones from Domine the way it controls speakers.

1. **Headphones as a device type.** Wired, USB and Bluetooth headphones appear in Domine with their own card and their own settings, separate from speaker setups. Never open a Bluetooth headset for input (CLAUDE.md), so a headset stays in high-quality output mode.
2. **Left and right levels.** A balance control and an independent level for each ear, with a mono option. This is useful for uneven hearing or a weak driver. It is stored per headphone UID.
3. **Several headphones, same audio.** Two or more headphones play the same mix at once, each with its own volume and left/right levels. This reuses the speaker aggregate, with every member getting the full stereo mix instead of one side.
4. **Sync between headphones.** Per-headphone delay and auto-calibration with the mic, so two Bluetooth headphones stay together for shared listening.
5. **Headphone EQ.** The Sound sheet's EQ and night mode per headphone, with a few presets (Flat, Bass, Voice).
6. **Mixed setups (later).** Speakers and headphones together: for example the speakers play the room and the headphones play a private mix at their own level.

Open questions: do two Bluetooth headphones share enough bandwidth (see the surround Bluetooth warning)? Should headphones get their own menu bar section? How does the volume link work when one headphone has no hardware volume?

## Known follow-ups

- **Battery charging icon:** the card can show it, but no IOBluetooth key for charging is confirmed yet. The reader tries three likely names; it needs checking on real hardware.
- **Pause before start:** `domine_kernel_start_faded_out` in `kernel.c` writes render-thread state without atomics. `surround.c` already got this fix; the stereo kernel needs the same.
- **Calibration peak finder:** it takes the highest positive correlation, so a speaker with inverted polarity can read 0.3 to 0.5 ms off. An envelope peak would fix it.
- **Reconnect failures:** a failed reconnect shows no failure line in the banner yet.
- **Timing reference speaker:** choosing a non-first speaker as the clock is not tested on hardware yet.
