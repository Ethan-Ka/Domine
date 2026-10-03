# Domine for Linux

Domine plays your desktop's audio across several speakers at once. In
**Stereo** it sends the left channel to one speaker and the right channel to
another (typically two Bluetooth speakers such as a pair of JBL Grips). In
**Surround** you place 3 to 16 speakers anywhere around you on a top-down
stage and Domine pans the sound between them. It is a port of the macOS app in
this repository and shares its real-time DSP code (`Sources/DomineDSP`).

The window is plain GTK 4 (no libadwaita). The audio side runs on PipeWire.

## Features

Same feature set as the macOS app, with the differences listed under
"Parity notes".

- **Stage.** A top-down room: you in the centre, FRONT at the top, a dashed
  guide circle at 2 m, one card per speaker with its name, angle, output and
  a 16 segment level meter.
  - Stereo: Front Left and Front Right sit level with the listener. Click a
    card to open **Choose Speaker**; right-click for a quick menu with Test.
    The header bar's swap button exchanges the two sides (their delay,
    balance and effects follow the physical speakers).
  - Surround: drag a card to set its angle and distance (0.5 to 10 m). Angles
    snap to 5 degrees; hold Alt to move freely. Click or right-click a card
    for its output, Choose Speaker, Test and Remove. **Add Speaker** places a
    new card in the widest gap; **Presets** (Quad, 5 Speakers, 7 Speakers,
    Ring) reassign the angles in card order, adding cards if the preset needs
    more.
- **Header bar.** Title and status line (Off, Starting, Playing, Mono
  fallback, Demo: Orbit, or the error), Stereo / Surround, swap, **Room**
  menu, on/off switch, and the menu (Preferences, Setup Guide, Quit).
- **Bottom bar.** Master volume, Test L / Test R (Stereo), **Sound...**,
  **Sync & Balance...**. In Surround also Width (10 to 90 degrees), Surround
  level, Orbit (Off to 2 turns per second) and Rotation (-180 to 180), Add
  Speaker and Presets, and a warning when more than 4 speakers are placed.
  **Play Demo** runs the showcase piece; an accent dot on the guide circle
  follows the sound and the status line names the section (Roll call, Left
  and right, Orbit, Swell, Drop).
- **Sync & Balance.** Stereo: one signed delay offset, -50 to +50 ms with a
  readout like "Right +4 ms", or +-300 ms with Extended range; Balance with
  a readout like "Left 20%". Surround: a delay (0 to 300 ms, on top of the
  automatic distance compensation) and a level per speaker. Both: Play Click
  Test, the latency each speaker's sink reports, Reset / Done, and Play Demo
  with the current section.
- **Choose Speaker.** Every output with its name, the last 4 characters of
  its id (two JBL Grips have the same name), a status line ("In use as Front
  Right", "Not connected", "Bluetooth, 2 channels") and Play tone.
- **Sound.** Presets (Flat, Bass Boost, Vocal, Loudness, Night), Link
  speakers (or edit one speaker at a time), 5 band EQ (80 Hz to 10 kHz,
  +-12 dB), bass enhancer and compressor. In Surround also the ambience:
  Spatial amount and Room size.
- **Rooms.** Save the current speakers under a name, switch between saved
  setups, rename or delete them. A room stores the mode and the speakers;
  their tuning comes back from the per-speaker-set records (below).
- **Preferences.** General: what closing the window does (quit, or keep
  playing in the background), start playing when Domine opens, launch at
  login, setup guide. Exclusions: apps that skip Domine and play through
  another output ("Excluded apps play through", default the previous
  output), with +/- and a volume per app, plus the volume of every app that
  is playing.
- **Mono fallback.** When a speaker disconnects while playing, a banner says
  so ("Front Right disconnected. Front Left plays both sides until it
  reconnects.") and the remaining speakers cover its position.
- **Volume keys.** The desktop's volume keys and sound settings change the
  Domine output's volume, which is Domine's master volume; the slider
  follows. The slider uses the same cubic scale as the desktop mixer.
- **First run.** A three step checklist: PipeWire is running, connect and
  choose your speakers, turn Domine on.

## Dependencies

Build: a C11 compiler, `make`, `pkg-config`, GTK 4.10 or newer and PipeWire
0.3 development files. Run: a PipeWire session (PipeWire with WirePlumber,
the default on current Fedora, Ubuntu and Debian desktops).

Debian / Ubuntu:

    sudo apt install build-essential pkg-config libgtk-4-dev libpipewire-0.3-dev

Fedora:

    sudo dnf install gcc make pkgconf-pkg-config gtk4-devel pipewire-devel

## Build and run

    cd linux
    make
    ./domine

Other entry points:

    ./domine --self-test     # checks the UI logic without opening a window
    ./domine --background    # starts without a window (used by Launch at login)
    make check               # headless engine self-test

To add Domine to the application menu, copy `domine` somewhere on your PATH
(for example `~/.local/bin`) and `domine.desktop` to
`~/.local/share/applications/`.

## How routing works

When you turn Domine on, the engine:

1. creates a virtual output named "Domine" and makes it the default output,
   remembering the previous default;
2. captures that output's monitor (the mix every app plays into);
3. runs the shared surround kernel on PipeWire's real-time thread: the left
   and right channels become virtual sources at -width and +width (plus
   ambience behind you in Surround), panned onto the speakers by their
   angles, with each speaker's effects, level and delay;
4. plays one stream per speaker, each pinned to its own output, so a missing
   speaker never falls back to the default output.

Turning Domine off removes the virtual output and restores the previous
default. Two speakers at -30 and +30 degrees (Stereo) get exactly the left
and right channels.

## Settings

Everything is saved in `$XDG_CONFIG_HOME/domine/settings.ini` (usually
`~/.config/domine/settings.ini`), a GLib key file. Speakers are stored by
their PipeWire `node.name`, never by their label. Like the Mac's per-pair
settings, the tuning of each speaker set (delay, balance or levels,
effects, and in Surround the positions) is also kept in a group named after
the sorted node names, so choosing the same speakers again, or switching to
a room, brings their tuning back.

Launch at login writes `~/.config/autostart/io.github.ethanka.Domine.desktop`.

## Parity notes and limitations

- No tray icon: GTK 4 has no status icon API. With "keep playing in the
  background", closing the window hides it and routing continues; launch
  Domine again to bring the window back, and use Quit in the window menu (or
  Ctrl+Q) to stop.
- Exclusions are on or off per app. The Mac's "Only during calls" mode has no
  equivalent, since PipeWire does not say when a call is active.
- Play tone (Choose Speaker) and Test need Domine to be on and playing
  through that speaker.
- No microphone auto-calibration: line the speakers up with the click test.
- The stage is mouse-driven; with the keyboard, use the card menus and the
  dialogs.
- Bluetooth: more than about 4 speakers on one adapter tends to drop out.
  Each Bluetooth speaker adds its own latency (often 150 to 250 ms); use
  Sync & Balance to line them up.
