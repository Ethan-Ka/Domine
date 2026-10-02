# Domine

A macOS app that plays the left channel of system audio on one Bluetooth speaker and the right channel on another. It was built for two JBL Grip speakers but works with any two outputs.

macOS can combine devices into a Multi-Output Device, but then every speaker plays both channels. Domine captures system audio with a Core Audio process tap, sends it to a private aggregate device, and writes left to one speaker and right to the other. The aggregate corrects clock drift between the two speakers, and a delay slider (1 ms steps) lines up their Bluetooth latency.

Status: in development. Progress is tracked in [the milestones](docs/SPEC.md#10-milestones).

## Requirements

- macOS 14.4 or later (process taps)
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Development

`project.yml` is the source of truth. The `.xcodeproj` is generated and not checked in, so every script regenerates it first. Build output goes to `build/`.

| Script | What it does |
|---|---|
| `./scripts/run.sh` | Build, quit any running copy, launch the Debug app |
| `./scripts/run.sh --logs` | Same, then stream the app's log in the terminal |
| `./scripts/test.sh` | Run every unit test |
| `./scripts/test.sh DomineDSPTests` | Run one test target (or `Target/Suite`, `Target/Suite/test()`) |
| `./scripts/build.sh` | Build only |
| `./scripts/stop.sh` | Quit Domine; force-quits after 5 seconds |
| `./scripts/logs.sh` | Stream log messages from the `com.ethankawley.Domine` subsystem |
| `./scripts/xcode.sh` | Open the project in Xcode for breakpoints |
| `./scripts/reset-permissions.sh` | Forget the audio capture and microphone grants so macOS asks again |
| `./scripts/clean.sh` | Delete `build/` and the generated project (`--xcode` also deletes old copies in Xcode's DerivedData) |
| `./scripts/install-driver.sh` | Build and install the virtual output driver, then restart coreaudiod (needs sudo) |
| `./scripts/uninstall-driver.sh` | Remove the virtual output driver and restart coreaudiod (needs sudo) |
| `./scripts/release.sh` | Archive, Developer ID sign the app and driver, notarize, and staple into `build/release/` (see [Releasing](#releasing)) |
| `./scripts/appcast.sh` | Build the Sparkle appcast and versioned update files into `build/release/appcast/` (see [Updates](#updates)) |

A typical loop: edit, `./scripts/test.sh`, then `./scripts/run.sh --logs` to try it.

While Domine is running, it mutes system audio everywhere except the two speakers. If the app hangs, `./scripts/stop.sh` brings the sound back: Core Audio removes a quit process's tap and private aggregate device.

The first time the engine starts, macOS asks for permission to capture system audio. Debug builds are signed with an Apple Development identity, so the grant survives rebuilds. If the speakers still go quiet after a rebuild, the grant is stale: run `./scripts/reset-permissions.sh` and allow access again.

The same commands without the scripts:

```sh
xcodegen generate
xcodebuild -scheme Domine -configuration Debug -destination 'platform=macOS' build
xcodebuild -scheme Domine -destination 'platform=macOS' test
```

## Virtual output

Optional. `Domine.driver` adds an output device named "Domine" that discards its audio. While Domine routes, it makes this device the system output, so the volume keys and the macOS volume overlay work as usual and Domine applies that volume to both speakers. Without it, Domine falls back to its own volume key handling (Settings > General).

```sh
./scripts/install-driver.sh      # add --dry-run to print the commands
./scripts/uninstall-driver.sh
```

Both ask for an admin password and restart coreaudiod, so all audio stops for a few seconds. After installing, Audio MIDI Setup lists "Domine". If it does not appear, check the driver host's log for a signature error:

```sh
log show --last 5m --predicate 'process CONTAINS "Core Audio Driver"'
```

## Releasing

One-time setup:

1. Install a Developer ID Application certificate in your login keychain (Xcode > Settings > Accounts > Manage Certificates).
2. Store notary credentials under a profile name, using an app-specific password from appleid.apple.com:

   ```sh
   xcrun notarytool store-credentials NAME --apple-id you@example.com --team-id TEAMID
   ```

Each release:

```sh
DEVELOPMENT_TEAM=TEAMID NOTARY_PROFILE=NAME ./scripts/release.sh
```

The stapled app and the signed driver are in `build/release/dist/`, and the zip to distribute (both together) is `build/release/Domine.zip`. Add `--dry-run` to print the commands without running them.

### Updates

Domine checks for updates with [Sparkle](https://sparkle-project.org). The feed URL is `SPARKLE_FEED_URL` in `project.yml` (now `https://ethan-ka.github.io/Domine/appcast.xml`); change it there if the appcast moves. Until `SPARKLE_PUBLIC_ED_KEY` holds a real key, the updater stays off: "Check for Updates…" is disabled, Settings hides the checkbox, and nothing is checked.

One-time setup:

1. Build once so Xcode downloads the Sparkle package (`./scripts/build.sh`).
2. Create the signing key. `generate_keys` stores the private key in the login keychain and prints the public key:

   ```sh
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   Back up the private key (`generate_keys -x private-key-file`) somewhere safe. Losing it means installed copies can no longer verify updates.
3. Put the printed public key into `SPARKLE_PUBLIC_ED_KEY` in `project.yml` and commit it.
4. Turn on GitHub Pages for the repo (Settings > Pages), serving either the `docs/` folder on `main` or a `gh-pages` branch. The appcast must end up at the feed URL.

Each release, after `release.sh`:

```sh
./scripts/appcast.sh          # add --dry-run to print the commands
```

It starts from the published appcast (so older entries stay), copies the zip to `build/release/appcast/Domine-VERSION.zip`, and runs Sparkle's `generate_appcast`, which signs the update with the key in the keychain and writes `appcast.xml`. Then:

1. Create a GitHub release tagged `vVERSION` and attach `Domine-VERSION.zip` (and the `.pkg`, if there is one). The appcast points at `https://github.com/Ethan-Ka/Domine/releases/download/vVERSION/`; set `DOWNLOAD_URL_PREFIX` to use another location.
2. Copy `build/release/appcast/appcast.xml` to the Pages source (`docs/appcast.xml` on `main`, or `appcast.xml` on `gh-pages`) and push.

Bump `CFBundleVersion` in `project.yml` for every release: Sparkle compares build numbers. A zip update replaces only the app. `generate_appcast` does not read `.pkg` files, so for a package that also installs the driver, the script prints a signed enclosure to put in the appcast by hand.

## Using two JBL Grips

1. In the JBL Portable app, turn off stereo pairing and party mode on both speakers. A stereo-paired pair shows up on the Mac as a single device.
2. Set the same EQ preset on both.
3. Connect both to the Mac in System Settings > Bluetooth. Both are named "JBL Grip"; renaming one there makes them easier to tell apart.
4. Disconnect any phones from the Grips. A phone can take over playback on one speaker.

## M0 spike

`Spike/M0/main.swift` is a throwaway command-line tool for checking that two speakers stay in sync on this Mac before the real audio path exists. It builds an aggregate of the two devices, points system stereo at channels 1 and 3, and makes the aggregate the default output.

```sh
swiftc -O Spike/M0/main.swift -o /tmp/domine-spike
/tmp/domine-spike list
/tmp/domine-spike run            # picks the two "JBL Grip" outputs
/tmp/domine-spike run UID_A UID_B
```

Ctrl-C restores the previous output and removes the aggregate. On a Grip each side plays about 6 dB quieter than normal during the spike, because the speaker averages in a silent second channel.

## Docs

- [docs/SPEC.md](docs/SPEC.md): design, audio path, and milestones
- [docs/mockups/](docs/mockups/README.md): screen layouts
- [CLAUDE.md](CLAUDE.md): rules for working in this repo
