# Setup / first run / system integration review (read-only)

1. Sources/Domine/UI/MenuAndPrompt: Sources/Domine/UI/Menu/UninstallPrompt.swift:21-28 + Sources/Domine/State/Uninstaller.swift:44-48
   Scenario: user confirms Uninstall; app stops routing, turns OFF launch at login, launches script with stdout/stderr to /dev/null, then terminates. The script then shows the admin password prompt. If the user cancels it (or osascript fails), script exits 1 silently: app is gone, login item disabled, nothing removed, no feedback anywhere.
   Fix: do the admin step in the app first (or have the script report failure via a notification/alert; or re-open the app on failure); only disable the login item after success (script can call `sfltool`/the app can do it at next launch). Confidence: high.

2. Sources/Domine/Audio/AudioCapturePermission.swift:69-81 (request) and Sources/Domine/State/AppModel+Accessibility.swift:28-35 (didBecomeActive)
   Scenario: Welcome step 3 / Setup "Audio capture". User clicks Allow, grants in the macOS prompt or Privacy pane while nothing is playing. Probe hears silence -> `.notConfirmed`; returning to Domine never re-probes, so the step never shows done until audio happens to flow through the engine (readMeterPeaks). Silent Mac = permanently "not confirmed" despite permission granted.
   Fix: re-run `captureAccess.request()` on didBecomeActive when status is `.notConfirmed`/`.unknown` and Welcome or Settings is visible; word the row "Granted? play any sound, then Check Again" and add a Check Again button. Confidence: high.

3. Sources/Domine/Audio/AudioCapturePermission.swift:84-88 (markWorking is one way); Sources/Domine/UI/Settings/SetupSection.swift:20-27
   Scenario: capture shows "working" (persisted in store.audioCaptureWorking keyed only to code signature). User later removes Domine from Screen & System Audio Recording. Status stays green forever, Request Access / Open Privacy Settings buttons are hidden, engine plays silence with no explanation.
   Fix: show the buttons always (secondary "Recheck"), and downgrade status when a probe or running engine delivers only zeros for N seconds while system audio plays. Confidence: medium-high.

4. Sources/Domine/State/UpdateChecker.swift:99-104
   Scenario: launch check writes lastUpdateCheck BEFORE the request. Mac just woke / Wi-Fi not up at login (very common with launch at login): fetch fails silently, and no retry for 24 h. Also never re-checks while the app stays running for days (background mode).
   Fix: set lastCheckKey only when outcome is not `.failed`; add a repeating timer (e.g. every 24 h) while running. Confidence: high.

5. Sources/Domine/State/UpdateChecker.swift:116-127 and 143-163
   Scenario: manual check with GitHub rate limit (403), 404 (no release yet), or malformed tag all show "Check your internet connection", which is wrong for non-network failures. A latest tag with only a prerelease suffix ("1.0.0-beta" vs "1.0.0") compares equal, so a final release over an installed beta is not offered. Automatic updates re-prompt every 24 h with no "skip this version".
   Fix: carry a reason in `.failed`; treat 404 as upToDate; compare pre-release suffix (release > prerelease); store skipped version. Confidence: medium.

6. Sources/Domine/State/UpdateChecker.swift:146-163 (showAlert)
   Scenario: automatic check finds an update at login while Domine is background/menu-bar only (no key window): `NSApp.activate` + `runModal` throws a blocking modal over whatever app the user is using.
   Fix: for non-manual checks, post a user notification or show a menu bar badge instead of runModal. Confidence: medium.

7. scripts/uninstall.sh:100-103 (ADMIN joined with `;`) 
   Scenario: admin commands are chained with `;`, so a failed `rm -rf` of the driver or app is ignored; the last command (kickstart/killall) sets the exit status, so the script prints "Removed Domine." and the user-level data is wiped while the driver may still be there.
   Fix: join with `&&` for the rm steps (keep `pkgutil --forget` tolerant), or verify afterwards that paths are gone and print which remain. Confidence: high.

8. scripts/uninstall.sh:34-38 and Sources/Domine/State/Uninstaller.swift:24-26
   Scenario: app run from a Gatekeeper-translocated path (/private/var/.../AppTranslocation/.../d/Domine.app, read-only nullfs) is passed as DOMINE_APP_PATH; rm fails silently (see 7) and the real copy in ~/Downloads or a non-standard folder (renamed "Domine 2.app") is never removed. Login item registered for the app is also not removed when the script runs standalone (only UninstallPrompt unregisters it).
   Fix: resolve the original bundle path (or skip translocated paths), and in the script run `osascript` / `sfltool resetbtm`-free approach: document that standalone use leaves the login item. Confidence: medium.

9. Sources/Domine/State/LiveDriverInstaller.swift:30-37 and Sources/Domine/State/AppModel+Driver.swift:41-43
   Scenario: install/remove failure always shows the generic "Could not install the Domine output." The real osascript stderr (permission, SIP, disk, codesign) is only logged. Users cannot report or fix it. Also no timeout: if the admin dialog is hidden behind another window the Install button stays "Installing…" disabled forever.
   Fix: include a short reason (last line of stderr) in driverFailure; bring app forward (NSApp.activate) before osascript; add a long timeout that terminates osascript. Confidence: medium.

10. Sources/Domine/State/LiveDriverInstaller.swift:31-37
   Scenario: copyItem of the bundle into the stage, then root `ditto` into /Library/Audio/Plug-Ins/HAL, preserves extended attributes, including com.apple.quarantine when the app came from a browser download without the pkg. A quarantined HAL plug-in can fail to load after the coreaudiod restart, so install "succeeds" but no device ever appears and status stays "installed" (plist present) while the device is absent.
   Fix: `ditto --noqtn` (or `xattr -dr com.apple.quarantine` on the staged copy); after install, wait for the UID to show in the catalog and show "Installed, but macOS did not load it" otherwise. Confidence: low-medium (not run on hardware).

11. Sources/Domine/State/DriverStatus.swift:11-17 with Sources/Domine/State/AppModel+Driver.swift:12-15
   Scenario: after Remove, installedDriverVersion becomes nil immediately, but `devicePresent` is true until coreaudiod restarts and the catalog refreshes, so the row briefly reads Installed with Remove still offered (and Install flows read `.installed`: installDriverFromWelcome does nothing). After Install the reverse: version is read at once, status "installed" before the device exists. No spinner covers the 3 to 6 s restart gap because `driverActivity` is cleared in the defer as soon as osascript returns.
   Fix: keep driverActivity set until the catalog reflects the expected presence (or 8 s timeout). Confidence: medium.

12. Sources/Domine/State/AppModel+Setup.swift:34-36 (setupState)
   Scenario: setupState (a view-body computed property) calls services.isAccessibilityTrusted() and spawns a Task on every render when the cached value differs; a side effect during view update that can cause repeated renders if trust flips. Also the Welcome checklist has no way to re-read driver/connect state on activation (welcomeState reads only cached `installedDriverVersion`), so a driver installed from Terminal while the sheet is up shows not done until Settings opens (refreshSystemStatus is the only caller of refreshDriverVersion).
   Fix: call refreshSystemStatus from didBecomeActive path is already done, but it is not invoked on Welcome's appearance; add `.onAppear`/activation refresh for the sheet and move the trust read out of the body. Confidence: medium (didBecomeActive in AppModel does call refreshSystemStatus, so only the first-appear case is open).

13. Sources/Domine/UI/Welcome/WelcomeView.swift:51-55 and Sources/Domine/State/AppModel+Welcome.swift:54-57
   Scenario: Continue is always enabled and silently marks hasCompletedWelcome even with undone steps (capture unconfirmed, driver skipped). The user never sees what is missing again except in Settings. "Not Now" on the driver step is not persisted, fine, but nothing on the main window later says the virtual output is missing.
   Fix: when steps are undone, label the button "Continue Anyway" and keep a one-line main window hint linking to Settings > Setup. Confidence: low-medium (design choice).

14. Sources/Domine/State/AppModel+Welcome.swift:6
   Scenario: "Unpair JBL" step is marked done as soon as 2 devices named "JBL Grip" are connected (name is the only key, against CLAUDE.md). A user with one Grip plus a different JBL "Grip"-named device, or with Grips paired as a stereo pair that still appear twice, gets a wrong done tick; a user who never connected speakers yet has to click to mark it.
   Fix: acceptable as a hint, but do not use as completion proof; keep manual confirmation only. Confidence: low.

15. Sources/Domine/State/PauseWatchdog.swift:48-52 with Uninstaller
   Scenario: appWillTerminate leaves the watchdog running so it pauses media after quit. UninstallPrompt calls stopRouting() first (cancels it), so fine; but a Quit from the update flow (user runs the .pkg while Domine routes) will pause the user's media mid-update, and the watchdog child runs from the binary the pkg is replacing.
   Fix: low priority; skip pause when the parent is exiting because the installer replaced the app (detect via bundle path mtime) or document. Confidence: low.

Verified OK: DriverCommand quoting (single-quote closing/escaping, AppleScript literal escaping) is correct and paths with spaces or quotes survive; -128 cancel detection works; Installer/scripts/postinstall restarts coreaudiod and exits 0; uninstall script covers app, driver, both pkg receipts, prefs, caches, logs, saved state, TCC; no Application Support write exists in the app (settings are UserDefaults only); SemanticVersion handles v prefix, missing parts, numeric compare; Accessibility trust is polled and refreshed on activation (stale-entry hint exists).
