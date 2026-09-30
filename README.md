# Domine

A macOS app that plays the left channel of system audio on one Bluetooth speaker and the right channel on another. It was built for two JBL Grip speakers but works with any two outputs.

macOS can combine devices into a Multi-Output Device, but then every speaker plays both channels. Domine captures system audio with a Core Audio process tap, sends it to a private aggregate device, and writes left to one speaker and right to the other. The aggregate corrects clock drift between the two speakers, and a delay slider (1 ms steps) lines up their Bluetooth latency.

Status: early development. Nothing here produces a usable app yet. See [the milestones](docs/SPEC.md#10-milestones).

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
| `./scripts/clean.sh` | Delete `build/` and the generated project |
| `./scripts/release.sh` | Archive, Developer ID sign, notarize, and staple into `build/release/` (see [Releasing](#releasing)) |

A typical loop: edit, `./scripts/test.sh`, then `./scripts/run.sh --logs` to try it.

While Domine is running, it mutes system audio everywhere except the two speakers. If the app hangs, `./scripts/stop.sh` brings the sound back: Core Audio removes a quit process's tap and private aggregate device.

The first time the engine starts, macOS asks for permission to capture system audio. Dev builds are ad-hoc signed, so a rebuild can leave a stale grant that makes the tap return silence. If the speakers go quiet after a rebuild, run `./scripts/reset-permissions.sh` and allow access again.

The same commands without the scripts:

```sh
xcodegen generate
xcodebuild -scheme Domine -configuration Debug -destination 'platform=macOS' build
xcodebuild -scheme Domine -destination 'platform=macOS' test
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

The stapled app is `build/release/export/Domine.app` and the zip to distribute is `build/release/Domine.zip`. Add `--dry-run` to print the commands without running them.

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
