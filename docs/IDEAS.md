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

## Website (site/index.html)

The page is one screen: logo art, Download and GitHub buttons, a headline and one paragraph. Colours come from the app icon, it uses the system font, and every text pair passes WCAG AA (body 14.8:1, grey text 6.3 to 6.8:1, button text 5.2:1). Done 2026-11-11: the headline and description cover Single mode ("One Bluetooth speaker or several, one sound system."), "up to 16" is gone, sync is described by the microphone calibration, and the social preview image matches. The Download button stays on the GitHub releases page on purpose: people trust a GitHub release more than a bare file link.

Still open, most valuable first:

| Idea | Why | Notes |
| --- | --- | --- |
| A real screenshot of the main window, light and dark | Nothing on the page shows what the app looks like | Stereo stage with two cards and the meters; swap with `<picture>` like the header art |
| Say how to open an unsigned build | Releases are development-signed, not notarized, so macOS blocks the installer on first open and the page never says why | macOS 14: right-click, Open. macOS 15 and later: System Settings > Privacy & Security > Open Anyway. Notarizing (needs a Developer ID, $99 a year) removes the step |
| Say any brand works | The page reads as if only matched speakers work | "Tested with JBL Grip and JBL Go 4" is specific and true |
| Show the version and what's new | Visitors can't tell if it's maintained | "Version 0.4.0", linked to the release notes |
| Requirements | Only "macOS 14.4 or later" is listed | Add "Apple silicon and Intel" (the build is universal) |
| A short privacy note | Domine asks for audio capture, the microphone (calibration only) and optionally Accessibility and an admin password | True facts: audio never leaves the Mac; the only network request is the GitHub update check |
| Three-question troubleshooting | The common problems have known fixes | Only one speaker shows up (unpair in the speaker's app); a speaker goes silent (a phone took it over); timing drifts (run Auto-calibrate) |
| Uninstall line | People look for it before installing | Menu bar menu, then Uninstall Domine |
| Secondary button border | The "View on GitHub" outline is 1.45:1 against the page, below 3:1 for UI edges | The label still identifies the button, but darken `--rule` on that border |

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
