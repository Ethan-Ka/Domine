# Feature gaps (read-only review)

1. [high] Routing failure hides its cause.
   - Where: `Sources/Domine/UI/Main/StageBannerState.swift:45-49`, `State/AppModel+MainWindow.swift:291,321`, `State/AppModel+Tuning.swift:97`.
   - Engine sets `.error(message)` with the real HAL error text (Engine.swift:392-428, 1202, 1409-1420), but the banner and status line always show the fixed "Could not start routing". The banner button is `.reconnect(uid: nil)`, which does not retry the start.
   - Fix: carry `engine.state`'s message into `StageBannerState` as a second line, and make the action "Try Again" (call `startRouting`). Add "Copy Report" (DiagnosticsReport exists) for the error case.

2. [high] Audio-capture permission denied is not surfaced on the stage.
   - Where: `AudioCapturePermission` / `AudioCaptureStatus` are only read by `UI/Settings/SetupState.swift:3`. Nothing in `stageBanner` (AppModel+MainWindow.swift:289) checks it.
   - A denied permission shows the generic error in item 1.
   - Fix: when `captureAccess.status` is denied, add a banner "Domine needs permission to capture system audio" with the `.openSettings` action (or a System Settings deep link).

3. [medium] Reconnect button has no failure feedback.
   - Where: `State/SpeakerReconnector.swift:71-75` (`_ = await connector.connect(address)`); `reconnectNow` returns Void.
   - IDEAS "Known follow-ups" already lists it. The spinner just disappears when the attempt fails, and the background loop gives up after 10 minutes silently.
   - Fix: keep `failed: Set<String>` / `gaveUp: Set<String>`, set it on a false result or after `giveUpAfter`, and show "Couldn't reach <name>. Turn it on and try again." on the card and banner.

4. [medium] Spatial amount and Room size have no UI.
   - Where: `State/AppModel+Surround.swift:254` `setSpatial(amount:roomMs:)` is never called (grep: no callers). SPEC 11.6 and 13 define "Spatial amount" and "Room size"; `SurroundSettings.spatialAmount/spatialRoomMs` are saved and sent to the engine (AppModel.swift:601).
   - Only presets can change them (SurroundPreset.swift:11).
   - Fix: add two sliders (Ambience, Room size) in the surround controls row or the Sound sheet (Surround), wired to `setSpatial`.

5. [medium] Rooms import gives no feedback when nothing is added.
   - Where: `State/AppModel+Rooms.swift:65-70` (`guard !added.isEmpty else { return }`); `UI/Rooms/RoomsFilePanels.swift:24`.
   - Importing an empty or fully merged file looks like nothing happened, and a successful import doesn't say how many rooms were added.
   - Fix: return the count and show a brief line in the Manage Rooms sheet ("Added 3 rooms.", "The file has no rooms.").

6. [medium] Keyboard shortcuts for the common actions are missing.
   - Where: `DomineApp.swift` has only Option-Command-D (Debug), Command-comma, Command-Q. No menu commands for Start/Stop Domine, Mute, Swap Sides, Auto-calibrate, Play Demo, or Test.
   - IDEAS lists "Keyboard shortcuts" as open, but menu-bar Commands cost little and give VoiceOver/keyboard users the same actions as the status menu (StatusMenu.swift:19-131).
   - Fix: add a `CommandMenu("Audio")` reusing `StatusMenuActions` (toggle, mute, swap in Stereo, auto-calibrate).

7. [medium] Volume key step size is fixed.
   - Where: `Input/VolumeKeyEvent.swift`, `State/AppModel+VolumeKeys.swift` (SPEC 4b: 1/16 or 1/64 with Option+Shift). No setting.
   - Listed in IDEAS as open; add a Step picker (1/16, 1/32, 1/64) next to "Show volume overlay" in Settings > Advanced.

8. [medium] Update available is only shown for a manual or daily check alert.
   - Where: `State/UpdateChecker.swift:139-165`. The alert is the only surface. A dismissed "Later" is not remembered, so there is no persistent "Update available" in the menu or Settings > General (SetupState has `.updateAvailable` at line 34, but only for the driver or setup).
   - Fix: store the last found version and show "Update available: x.y.z" in the status menu (one item) until installed.
   - Value: medium. Check before building: it may already be covered by SetupState.

9. [medium] Per-app volume is available only in the status menu.
   - Where: `UI/Menu/StatusMenuAppRow.swift`, `StatusMenu.swift:141`. The main window has no entry (grep UI/Main: none), and Surround mode has no UI difference either.
   - Fix: add an "Apps" popover or sheet in the main window's bottom bar that reuses `StatusMenuAppRow`. Skip if the menu is considered enough.

10. [medium] Low battery gives only a passive banner.
    - Where: `UI/Main/StageBannerState.swift:58` shows it only while the main window is open. In background mode (SPEC 6a) the menu bar icon is the only place, and the "icon gets a warning badge" setting covers the menu (IDEAS Done list).
    - Fix: confirm the badge fires for low battery; if not, add it. Optional: one notification per speaker per drop below 15%.
    - Value: medium, low certainty (verify `MenuBarLabelState.swift` first).

11. [medium] Single mode lacks parity items.
    - Where: `State/AppModel+MainWindow.swift:316` Single reads only "Playing"; Rooms save Single's settings (Room.mode) but `AppModel+Rooms.swift` stores one uid.
    - Single has no Test button state difference, but missing: speaker name next to the title (card says "Speaker" via `singleSpeakerTitle`, AppModel+MainWindow.swift:398), so with two identical "JBL Grip" the card shows the suffix only.
    - Fix: confirm the card still shows `uidSuffix` and battery in Single (it does via positionCard); nothing to change except naming. Low value, listed for completeness. (Not counted as a gap if the suffix shows.)

12. [medium] Exclusion failures are silent.
    - Where: `Audio/ExclusionResolver.swift:77-79` (`try hal.processIsRunningInput` inside a catch path) and Engine.swift:958,1011 log in-place update failures then rebuild; the UI never tells the user that an excluded app was not found or the tap failed.
    - Fix: in Settings > Exclusions show per-row status ("Not running", "Excluded now") from the resolved process set.

13. [medium] Rooms do not switch automatically; no way to see which room matches the connected speakers.
    - Where: `State/AppModel+Rooms.swift:55` only clears the current room on manual change.
    - IDEAS "Automatic room switching" is open. Small first step: when exactly one saved room's speakers are all connected and none is selected, show a banner "Use room <name>?" with a button.

14. [medium] No "Forget this speaker" or "Reset all settings" in the main window.
    - Where: `State/BluetoothSpeakersModel.swift` has forget for the Bluetooth sheet only. Per-speaker stored tuning (PairSettings per pair and Single per uid, `Settings.swift:41-68`) can only be reset via Reset in Sync & Balance, which per SPEC 4a leaves offsets alone.
    - Fix: Settings > Advanced "Reset all speaker settings" with confirmation. Low urgency.

Note: items 11, 14 are weak; 8, 10 need a quick check before building. Reported count is 14 and the first 7 are firm.
