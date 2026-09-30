# Domine UI mockups

These are HTML mockups from the design canvas. They will not render on their own (they depend on the canvas runtime), so read them as markup: the inline styles give exact sizes, positions, labels, and control types. Build every screen with default SwiftUI/AppKit controls; do not copy colors or custom styling unless the native control can't express the layout.

| File | Screen | Notes |
|---|---|---|
| Main.dc.html | Main window, playing | ~640 x 480. Toolbar: title + status line, Stereo/Quad segmented control (Quad disabled in v1), swap button, on/off switch. Stage: Mac icon centered, "FRONT" label at top, Front Left / Front Right cards at the top corners, Rear Left / Rear Right as dashed placeholders at the bottom corners, lines from Mac to each card. Bottom bar: master volume slider with %, Test L / Test R, "Sync & Balance..." button. Clicking a card opens Assign. |
| Assign.dc.html | Choose speaker sheet | Sheet over main window. Radio list of outputs with name, UID suffix, status line, and a Play tone button per row. Cancel / Use This Speaker. |
| Tuning.dc.html | Sync & Balance sheet | Delay offset slider (-50..+50 ms, readout like "Right +4 ms"), Extended range checkbox, Play Click Test, reported latencies line, Balance slider. Reset / Done. |
| Welcome.dc.html | First-run setup | Three-step checklist with per-step action buttons, Continue. |
| Disconnected.dc.html | Mono fallback | Front Right card in error state, Front Left tagged "L+R" with "Mono fallback · Full mix", banner explaining auto-reconnect. Toolbar status "Mono fallback · Waiting for Front Right". |
| Quad.dc.html | Quad mode (v2 only) | All four positions active. Do not build in v1; keep the layout able to support it. |
| SettingsGeneral.dc.html | Settings > General | Standard Settings scene, form with right-aligned labels. |
| SettingsExclusions.dc.html | Settings > Exclusions | App list with +/- buttons, per-app mode, "Excluded apps play through" popup. |
| MenuBar.dc.html | Background mode | MenuBarExtra content shown only when the window is closed and audio keeps playing. |

The speaker cards show: position name, side tag (L, R, L+R), device name + 4-character UID suffix, one status line, and a 16-segment horizontal level meter (green, then yellow for the top 3, red for the last 2).
