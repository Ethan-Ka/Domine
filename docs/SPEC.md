# Domine: Technical Specification

Domine is a small macOS windowed app that splits system stereo audio across two Bluetooth speakers: the left channel goes to one speaker, the right channel to the other. The reference hardware is a pair of **JBL Grip** speakers (section 1a). Other Bluetooth speakers and wired outputs should work, but every default, test plan, and tuning decision is made for the Grip first.

## 1. Goals and non-goals

### Goals (v1)
- Route all system audio so the left channel plays on Device A and the right channel plays on Device B.
- Show a live status view: the Mac in the center, each speaker placed at its position around it (front left, front right, and later rear left and rear right), with connection state, volume, and a level meter per speaker.
- Let the user assign a device to each position by clicking it, and swap left and right with one click.
- Keep the two devices in sync: correct clock drift automatically and let the user trim the fixed latency difference by hand.
- Per-side volume trim so mismatched speakers can be balanced.
- A test tone per side so the user can confirm which speaker is which.
- Survive devices disconnecting and reconnecting without the user reopening the app.
- Remember settings per device pair (keyed by device UID).
- Tell two identically named speakers apart ("JBL Grip" and "JBL Grip").
- One master volume that moves both speakers together, and stays linked when someone presses the volume buttons on either speaker.
- Keyboard volume keys control Domine's master volume (section 4b).
- Mono fallback: if one speaker drops, the other plays the full mix until it returns (section 7).
- Restore the previous system output when Domine stops or quits (section 4c).
- Keep playing in the background with a menu bar item when the window is closed (section 6a).
- App exclusions: chosen apps skip the speaker pair and play through another output (section 3b).

### Goals (v2)
- Surround mode: 3 to 16 speakers placed anywhere around the listener, positions dragged on a top-down stage, sound panned between them like a surround system (section 13). Stereo mode stays as it is.
- A built-in showcase demo, "Play Demo", that moves bass and kicks around the room so the user hears and feels each speaker, the left/right split, and a full orbit (section 14).
- A Linux port on PipeWire with the same routing idea, the same render kernel, and the same stage (section 15).

### Non-goals (v1)
- Per-app routing (only system-wide audio).
- More than two outputs in v1. Surround mode (section 13) adds 3 to 16 speakers in v2 and replaces the earlier four-speaker quad plan (section 11).
- Automatic latency calibration with the Mac microphone (planned for v2, see section 10).
- Mac App Store distribution (see section 8).

## 1a. Target hardware: JBL Grip

| Property | Value | What it means for Domine |
|---|---|---|
| Driver | One 43 x 80 mm full-range driver, mono | The speaker sums whatever stereo it receives. Each Grip must receive its side on **both** channels, or it plays 6 dB quieter (section 3.2). |
| Bluetooth | 5.4, A2DP 1.4, AVRCP 1.6 | Classic A2DP connection to the Mac. AVRCP carries absolute volume, so hardware volume buttons show up as volume property changes on the Mac side. |
| Codecs | SBC, AAC | macOS will normally pick AAC. Expect roughly 150 to 250 ms of output latency per speaker. Two identical Grips should land close to each other, but not exactly. |
| Frequency response | 70 Hz to 20 kHz (-6 dB) | No bass management or subwoofer logic needed. |
| Built-in pairing | Stereo pair and party mode over Auracast, set up in the JBL Portable app | Must be **off** on both speakers while Domine is running. A stereo-paired Grip set appears to the Mac as one device. |
| Multipoint | Supported | A phone still connected to a Grip can take over playback. Setup instructions tell the user to disconnect other sources. |
| Device name | Both report "JBL Grip" by default | The UI shows a short UID suffix next to each name and relies on the test tone to identify sides. Suggest renaming in System Settings > Bluetooth. |
| Auto power-off | Powers down after a period of no audio | Treated as a normal disconnect (section 7). |

Auracast is not usable from the Mac: as far as I know macOS does not act as an Auracast broadcast source, so Domine uses two ordinary A2DP connections.

In-speaker processing (JBL's "AI Sound Boost" and the app EQ) runs independently on each unit. The setup guide tells the user to set the same EQ preset on both Grips in the JBL Portable app; Domine does not try to compensate.

## 2. Platform and toolchain

| Item | Choice |
|---|---|
| Minimum macOS | 14.4 (Core Audio process taps arrived in 14.2; 14.4 fixed several tap bugs) |
| Language | Swift 6 for app and device logic; C for the real-time render kernel |
| UI | SwiftUI single `Window` scene, default macOS controls, about 640 x 480 pt, resizable within limits. Normal Dock app, not a menu bar app. |
| Project generation | XcodeGen (`project.yml` is the source of truth; never hand-edit `.xcodeproj`) |
| Build and test | `xcodebuild` from the command line |
| Distribution | Developer ID signed, hardened runtime, notarized, outside the App Store |
| Launch at login | `SMAppService.mainApp` |

## 3. How the audio path works

### 3.1 The core problem
macOS gives you two built-in ways to combine devices, and neither does this job on its own:

- A **Multi-Output Device** sends the same stereo stream to every device. Both speakers play both channels.
- An **Aggregate Device** combines devices into one device with more channels (two stereo speakers become a 4-channel device: channels 1 and 2 are Device A, channels 3 and 4 are Device B). macOS still sends system stereo to channels 1 and 2 only, unless the stereo channel preference is changed.

Domine takes over the routing itself so it can control exactly which samples reach which speaker.

### 3.2 Chosen approach: process tap plus private aggregate device
1. Create a **system-wide process tap** with `CATapDescription` (stereo global tap that excludes Domine's own process) and `AudioHardwareCreateProcessTap`. Set the tap's mute behavior to `.muted` so the original audio does not also play through the current default output.
2. Create a **private aggregate device** with `AudioHardwareCreateAggregateDevice`:
   - `kAudioAggregateDeviceIsPrivateKey = true` so it never appears in System Settings.
   - Sub-devices: Device A and Device B (`kAudioAggregateDeviceSubDeviceListKey`).
   - Main sub-device (clock source): Device A (`kAudioAggregateDeviceMainSubDeviceKey`).
   - Drift compensation on for Device B (`kAudioSubDeviceDriftCompensationKey = 1`) and off for Device A.
   - The tap added via `kAudioAggregateDeviceTapListKey` with `kAudioSubTapDriftCompensationKey = 1`.
3. Register an IOProc on the aggregate device (`AudioDeviceCreateIOProcIDWithBlock` or the function-pointer variant). Each cycle it reads the tapped stereo input and writes output buffers:
   - Device A channels 1 and 2 both receive the left channel.
   - Device B channels 1 and 2 both receive the right channel.
   - This "mono per speaker" mode is required for the Grip. Its single driver plays (ch1 + ch2) / 2, so sending the left signal on ch1 alone would come out at half amplitude. For stereo speakers it is still the right default.
   - Per-side gain and per-side delay applied in the kernel.
   - The aggregate can publish its stream layout a moment after `AudioHardwareCreateAggregateDevice` returns. Poll `kAudioDevicePropertyStreamConfiguration` until the output channel count equals the sub-devices' sum and the tap's input stream is present, rather than assuming it is ready.
4. Start with `AudioDeviceStart`. Tear down in reverse order on stop: stop device, destroy IOProc, destroy aggregate, destroy tap.

Why this approach: the tap needs no kernel extension, no admin password, and no coreaudiod restart, and the user never has to touch Audio MIDI Setup. The cost is the macOS 14.4 minimum and a one-time audio capture permission prompt. The optional virtual output device (section 3.3) adds native volume keys and a stable tap clock on top of this path; it does not replace the tap.

### 3.3 Virtual output device

Domine ships an optional user-space `AudioServerPlugIn` driver, `Domine.driver`, installed in `/Library/Audio/Plug-Ins/HAL`. It publishes one output-only device:

| Property | Value |
|---|---|
| Name | "Domine" (manufacturer "Domine") |
| UID | `com.ethankawley.Domine.VirtualOutput` |
| Transport | Virtual |
| Streams | One output stream, 2 channels, 32-bit float, interleaved |
| Sample rates | 44100 and 48000 Hz |
| Controls | Volume (scalar 0...1 with a dB range of -64 to 0 dB, main element, output scope, settable) and mute |
| Default device | Can be the default output and the default system output |

The device is a null sink: it discards every sample written to it, but it runs a steady clock from `mach_absolute_time` at its nominal rate. Both 44100 and 48000 Hz are offered because Domine matches the default output's rate to the Grips (section 4a), and Grips run at 44100 Hz when healthy.

While Domine routes and the driver is installed, the system default output is this device:
- The volume keys and the system volume HUD control it natively. The HUD shows "Domine".
- Domine reads its volume and mute and applies them to the Grips' linked hardware volume (section 4a). The device itself never changes the audio; it only stores the values.
- The process tap captures from a stable non-Bluetooth clock, so the tap is not tied to a Bluetooth device that can drop out.

The process tap stays the audio source. The virtual device carries no audio to Domine.

DeviceCatalog hides every device whose UID starts with `com.ethankawley.Domine.` from the speaker list, so the virtual device can never be picked as a speaker. Volume and mute persist across coreaudiod restarts through the host's `WriteToStorage` and `CopyFromStorage`.

The driver is plain C in `Sources/DomineDriver/`, built as the `DomineDriver` bundle target, and follows the structure of Apple's NullAudio sample (plug-in object, one device, one output stream, volume and mute controls). IO callbacks use atomics only. A mutex guards non-IO property state, as in Apple's sample. Without the driver, Domine falls back to the previous behavior: the default output is the device from section 3b and the volume keys go through the event tap in section 4b.

### 3.4 Prototype shortcut (Milestone 0 only)
Before building the tap path, validate that two Bluetooth speakers can stay in sync on this Mac at all: build the aggregate device in code, set `kAudioDevicePropertyPreferredChannelsForStereo` to `[1, 3]`, and make it the default output. This sends left to Device A and right to Device B with zero custom DSP. On the Grip each side will play about 6 dB quieter than normal because the speaker averages the silent second channel in; that is expected for the spike and fixed by the real kernel. Throw this code away after the spike.

## 3b. App exclusions

- The process tap already excludes Domine's own process. Excluded apps are added to that list by translating their bundle ID to Core Audio process objects (`kAudioHardwarePropertyTranslatePIDToProcessObject`, and `kAudioHardwarePropertyProcessObjectList` for apps that start later).
- Excluded processes are not tapped and not muted, so they play through the system default output. While Domine runs, it sets the default output to the "Excluded apps play through" device chosen in Settings (default: the previous output from section 4c). Included apps are muted on that device by the tap, so only excluded apps are heard there.
- Each exclusion has a mode: Always, or Only during calls (the app is excluded while it has an active input stream, detected with `kAudioProcessPropertyIsRunningInput`).
- The exclusion list changes at runtime; rebuild the tap when it changes or when an excluded app launches or quits. A rebuild causes a short gap, so debounce changes by about 500 ms.
- Default suggestions on first open: FaceTime, zoom.us, Microsoft Teams, Discord. None are excluded until the user adds them.

Decision (virtual output and exclusions): while any exclusion is effectively active (the resolved process set is not empty), the default output is the "Excluded apps play through" device or the saved previous output, never the virtual output and never one of the two speakers, so excluded apps are heard. When no exclusion is active, the virtual output is preferred as in section 3.3. Domine switches when the active state changes, after the 500 ms debounce above. While the virtual output is not the default, the volume keys use the event tap fallback in section 4b.

## 3a. Level meters

Each speaker card shows a post-kernel peak meter for the signal Domine sends to that speaker. The render kernel writes one peak value per output position into an atomic float per cycle; the UI polls at 30 Hz and applies a short decay. No audio data crosses to the main thread, only these floats.

## 4. Sync and latency

Two different problems, handled differently:

- **Clock drift** (the two devices run at slightly different real sample rates, so they slowly slide apart): handled by the aggregate device's drift compensation on the non-main sub-device. No app code needed beyond setting the key.
- **Fixed latency offset** (Bluetooth speakers buffer differently, often 100 to 300 ms, and models differ): handled by a delay line in the render kernel. The user adjusts a "Delay Left / Delay Right" slider in milliseconds; negative means delay the other side. Sign convention: a positive offset delays the right speaker (use it when the right speaker plays early); negative delays the left. Only one side is ever delayed; the kernel converts the signed value into a delay on one channel. With two Grips the offset should be small, so the slider shows -50 to +50 ms in 1 ms steps by default, with an "extended range" toggle for -300 to +300 ms (needed when pairing a Grip with a different speaker model). Store the offset per device pair, since it can differ after a firmware update or codec change.

Note: at typical listening distances, an offset under about 1 ms is inaudible as a timing problem but will shift the stereo image toward the earlier speaker. That is why the step size is 1 ms and not coarser.

### 4a. Volume

The process tap captures audio before any device volume is applied, so the default output's volume does not change what the Grips play. Domine handles volume itself:
- With the virtual output device installed (section 3.3), it is the default output while routing. Domine listens to its volume scalar and mute and applies them to both Grips' hardware volume as the master volume. A change Domine makes to the Grips' volume (from the slider or a Grip's buttons) is written back to the virtual device, so the system HUD and the menu bar volume stay in step.
- A master volume slider in the menu sets `kAudioDevicePropertyVolumeScalar` on both Grips (output scope, main element; fall back to per-channel elements if the main element is not settable). Over AAC/AVRCP this is the speaker's own hardware volume, so there is no loss of resolution.
- Domine listens for volume changes on both devices. If one changes and Domine did not cause it (someone pressed the + button on a Grip), apply the same value to the other speaker. Use a short suppression window after Domine's own writes so the two listeners do not bounce changes back and forth.
- Per-side trim (section 1 goals) is applied in the kernel as a gain, separate from hardware volume.
- Without the virtual output device, volume keys are handled as described in section 4b.

Report the Core Audio latency values (`kAudioDevicePropertyLatency`, `kAudioStreamPropertyLatency`, `kAudioDevicePropertySafetyOffset`) in a debug panel, and use their difference as the initial default offset. Bluetooth devices often report these inaccurately, so the manual slider always wins.

Sample rate: never set the nominal sample rate (`kAudioDevicePropertyNominalSampleRate`) of a Bluetooth speaker. Each speaker keeps the rate it reports, which follows its Bluetooth codec (a freshly connected JBL Grip reports 44.1 kHz, the only rate it offers). Reason: on hardware, Grips that had been forced to 48 kHz kept reporting 48 kHz while their AAC encoder still ran at 44.1 kHz with no conversion, so everything, even plain macOS playback with no Domine, played about 8% slow and 1.5 semitones low until the speaker was power-cycled. The aggregate runs at the main sub-device's (Device A's) rate, and the kernel, delay, tone, and click use that rate. If Device B reports a different rate, log a warning and let the aggregate's drift compensation convert it. The tap follows the system default output's rate, so when the default output is not Bluetooth (for example the built-in speakers) and supports Device A's rate, Domine sets it to that rate while running and restores its previous rate on stop. Otherwise the tap's drift compensation converts it.

### 4b. Volume keys

With the virtual output device installed (section 3.3), the volume keys need nothing from Domine: macOS changes the virtual device's volume and shows its own HUD, and Domine follows that volume (section 4a). The event tap below is the fallback when the driver is not installed.

- Off by default until the user enables it in Settings > General (it needs Accessibility permission).
- Implementation: a `CGEventTap` on `NX_SYSDEFINED` events (subtype 8) catches volume up, down, and mute while Domine is running, applies the change to Domine's master volume, and swallows the event so macOS does not also adjust the muted default device.
- Step size matches macOS: 1/16 of full scale, or 1/64 with Option+Shift held.
- Show feedback: a small volume overlay near the bottom of the screen styled like the system HUD. There is no public API to drive the real system HUD, so this is Domine's own borderless panel.
- If Accessibility permission is missing, the Settings checkbox shows a "Grant access" button and the keys keep their normal behavior.
- When Domine is off, the tap passes every event through untouched.

### 4c. Restore previous output

- On start, read `kAudioHardwarePropertyDefaultOutputDevice` and store the device UID as "previous output".
- On stop, quit, or crash recovery at next launch, set the default output back to that UID if the device still exists; otherwise leave the current default alone.
- Setting in General: "Switch back to the previous output" (on by default).
- The previous output is also the default device used for excluded apps, unless the user picks another one (section 3b).

### 4d. Signal quality

Everything Domine controls is transparent; the Bluetooth link is the only lossy stage.
- **Float32 end to end.** The tap, the aggregate's streams, and the kernel all carry 32-bit float. No integer conversion, no dither, no limiter or clipper on program audio.
- **No sample-rate conversion when the rates match.** macOS mixes every app at the default output's rate, and the tap delivers at that rate. The aggregate runs at Device A's rate. Domine sets the default output to Device A's rate (section 4a), waits up to 1 s for the device to report the new rate before creating the tap, then checks the tap's format. If the tap still came up at the old rate, Domine waits for the rate to settle and rebuilds the tap once. At start the Engine log prints the whole chain (default output rate, tap rate, aggregate rate, each speaker's rate) and either "no sample-rate conversion" or "SRC at" followed by the stage. Drift compensation stays on for the tap and Device B at the highest quality (`kAudioAggregateDriftCompensationMaxQuality`); at matching rates it only trims clock drift of a few ppm.
- **Bit-exact kernel at unity.** With trim gains 1.0, delay 0, no swap, the test tone and click test off, and not muted, each speaker gets exactly the input samples of its side, bit for bit, once any fade has finished (every fade steps an integer counter that ends exactly at full or zero, and the multiply is then skipped). The kernel never adds gain: trim gains above 1.0 are held at 1.0, and the tone, click, and mute crossfades are convex blends, so they cannot push the output past the larger of the program peak and the test signal's own level. The mono fallback, (L + R) / 2, is the only mixing. Unit tests check all of this with exact bit-pattern equality.
- **AAC over Bluetooth is the one lossy stage.** macOS encodes each speaker's stream for Bluetooth (AAC at 44.1 kHz for the JBL Grip) and picks the codec itself; Domine cannot choose a lossless one.

## 5. Real-time render kernel (C)

Lives in `Sources/DomineDSP/` as a small C target exposed to Swift through a module map.

Rules for anything called from the IOProc:
- No memory allocation, no locks, no Objective-C or Swift runtime calls, no logging, no file or network I/O.
- All buffers (including the delay ring buffers, sized for 300 ms at 96 kHz) are allocated once at start.
- Parameters (gains, delay samples, mode, swap flag) are read from a struct updated through C11 atomics. The UI thread writes, the render thread reads.

API sketch:

```c
typedef struct DomineKernel DomineKernel;

DomineKernel *domine_kernel_create(double sampleRate, uint32_t maxFrames);
void domine_kernel_destroy(DomineKernel *k);

void domine_kernel_set_gains(DomineKernel *k, float leftGain, float rightGain);
void domine_kernel_set_delay_ms(DomineKernel *k, float signedDelayMs);
void domine_kernel_set_mode(DomineKernel *k, int monoPerSpeaker, int swapSides, int monoFallback);
void domine_kernel_set_test_tone(DomineKernel *k, int side); // 0 off, 1 left, 2 right
void domine_kernel_set_muted(DomineKernel *k, int muted);     // 50 ms linear fade (section 7)
float domine_kernel_peak(DomineKernel *k, int position);      // meters (section 3a); 0 = A, 1 = B

// Called from the IOProc. in: interleaved or deinterleaved stereo from the tap.
// outA / outB: the output buffers for Device A and Device B inside the aggregate.
void domine_kernel_process(DomineKernel *k,
                           const AudioBufferList *in,
                           AudioBufferList *out,
                           uint32_t frames,
                           uint32_t outAChannelOffset,
                           uint32_t outBChannelOffset);
```

The channel offsets come from the aggregate's output stream layout, which the Swift side reads once at start (`kAudioDevicePropertyStreamConfiguration`). Do not assume the layout; Bluetooth devices can expose one stereo stream or separate mono streams. An offset is a flat index across all output channels in buffer order (buffer 0's channels, then buffer 1's). `DOMINE_NO_DEVICE` as the B offset means only Device A is present (mono fallback).

Input streams in the aggregate list sub-device inputs first, then the tap's streams, so the tap's first buffer index is the number of sub-device input buffers. Bluetooth outputs have no input streams (macOS splits them into separate ":input" and ":output" devices); the engine refuses to start if one does, and disables any other sub-device inputs with `kAudioDevicePropertyIOProcStreamUsage`. This ordering is an assumption to confirm on hardware.

The IOProc itself is a C function in `DomineDSP` (`domine_kernel_ioproc`, passed to `AudioDeviceCreateIOProcID` with the kernel as client data), so no Swift runs on the audio thread at all. The Swift side stores the layout in the kernel through atomics before starting the device.

## 5a. Effects

Built-in effects run inside the kernel, per output position, so position A and position B each have their own instance of every stage and never share state. The chain, in order:

1. EQ (five bands: low shelf, three peaking, high shelf; each +-12 dB, with frequency and Q).
2. Bass enhancer.
3. Compressor/limiter.
4. Trim gain (section 4a).
5. Delay (section 4).

The chain runs on the program source right after the side mapping (swap, mono fallback) and before the click source and the delay line, so it works on one continuous stream per position, test signals are never colored by it, and changing the delay does not disturb filter state. The calibration chirp and test tone bypass it.

Every stage has an enable flag. A disabled stage fades to a no-op over about 10 ms and is then skipped entirely. With every stage disabled the kernel output is bit-exact passthrough, so the guarantees in section 4d stay true. Enabling any stage means that stage's processing is, by design, no longer transparent, and the trim gain still never adds gain.

Module contract (`Sources/DomineDSP/include/DomineEffects.h`). Each effect is its own module with its own header `DomineX.h` and source `x.c`:

```c
typedef struct X X;
X *x_create(double sampleRate);                 // allocates; not real-time
void x_destroy(X *x);
void x_set_params(X *x, const XParams *p);      // any thread; atomics only
void x_process(X *x, float *samples, uint32_t frames); // in place, real-time safe
int x_is_idle(const X *x);                      // settled no-op, kernel may skip
```

Parameters cross threads through a seqlock over atomic words (or an atomically swapped double buffer); the render thread never waits. `x_process` picks up changes itself and smooths them over about 10 ms. The kernel exposes one setter per stage, such as `domine_kernel_set_eq(k, position, params)`. Create and destroy happen only inside `domine_kernel_create` and `domine_kernel_destroy`.

EQ details: RBJ cookbook biquads, double precision state, float input and output. A band at exactly 0 dB has identity coefficients and is skipped once settled. Parameter changes slide the coefficients linearly over 10 ms.

### Per-app volume

The aggregate may hold several process taps: one global tap that excludes the apps with their own volume, plus one tap per such app. Both kernels sum up to 8 taps ahead of the existing chain. `domine_kernel_set_tap_layout(k, tapCount, firstBuffer[], channels[], interleaved[])` (and `domine_quad_set_tap_layout`) gives each tap's first buffer index in the aggregate input list, its channel count, and whether it is one interleaved buffer or one buffer per channel. Each tap becomes stereo the same way a single tap does, is multiplied by its gain, and the results are added. `domine_kernel_set_tap_gain(k, tap, gain)` (and `domine_quad_set_tap_gain`) sets a gain from 0 to 1 that ramps linearly over 20 ms. With a tap count of 0 (the default) the kernel reads the single tap as before; with one tap at gain 1 the output is bit-identical to that. Missing or short tap buffers read as silence. The layout crosses threads through a seqlock; gains through atomics.

## 6. App structure (Swift)

```
Domine/
  project.yml
  CLAUDE.md
  docs/SPEC.md
  Sources/
    Domine/                 app target
      DomineApp.swift       Window scene entry point
      UI/
        MainView.swift      toolbar (Stereo/Surround, swap, on/off), stage, master volume, test tones
        StageView.swift     Mac in the center, one SpeakerCard per position, connector lines
        SpeakerCard.swift   role, device name + UID suffix, volume, status, level meter
        AssignSheet.swift   choose the device for a position, with Play tone per row
        TuningSheet.swift   delay offset, extended range, balance, reported latencies
        WelcomeView.swift   first-run checklist (unpair in JBL app, connect, allow capture)
        SettingsView.swift  General (volume keys, restore output, close behavior, auto-start) and Exclusions tabs
        StatusMenu.swift    MenuBarExtra content shown only in background mode
        VolumeHUD.swift     borderless volume overlay for the volume keys
        DebugView.swift     reported latencies, sample rates, stream layout
      Audio/
        CoreAudioHAL.swift  thin typed wrappers over AudioObjectGetPropertyData etc.
        DeviceCatalog.swift enumerates outputs, listens for add/remove/default changes
        TapController.swift creates and destroys the process tap
        AggregateBuilder.swift builds the private aggregate dictionary
        Engine.swift        owns tap + aggregate + IOProc + kernel; start/stop/rebuild
        OutputRestorer.swift saves and restores the previous default output
        Exclusions.swift    bundle ID to process object mapping, call detection
      Input/
        VolumeKeyTap.swift  CGEventTap for media volume keys
      State/
        Settings.swift      per-pair settings keyed by the two UIDs in sorted order ("uid1|uid2"), stored in UserDefaults.
                            Delay and balance describe the physical speakers, so when Front Left is the second
                            UID the stored delay and balance are read and written with their sign flipped.
        AppModel.swift      @Observable model the UI binds to
    DomineDSP/              C target: kernel.c, include/DomineDSP.h, module.modulemap
    DomineDriver/           C AudioServerPlugIn bundle for the virtual output device (section 3.3)
  Tests/
    DomineDSPTests/         kernel tests (mapping, gain, delay, swap, tone)
    DomineTests/            engine state machine tests against a fake HAL
```

`CoreAudioHAL` sits behind a protocol (`AudioHAL`) so `DeviceCatalog` and `Engine` can be tested with a fake that simulates devices appearing and vanishing.

## 6a. Window and background behavior

- Closing the window does not stop audio by default. Domine switches its activation policy to `.accessory` (no Dock icon). The `MenuBarExtra` is always present, in the foreground too (except in the test host), with status, per-speaker connection dots, master volume, Open Domine, Settings, and Quit.
- Reopening the window (from the menu bar item or by launching the app again) is ordered: close the menu panel, switch to `.regular`, then on the next runloop turn bring the existing main window forward (open it only if none exists, never a second), then activate the app.
- Setting in General: "Keep playing in the background" or "Stop playing" when the window closes.
- "Start routing when both speakers connect" works in background mode, so with launch at login on, Domine starts on its own when the Grips power up.
- The menu bar item is always shown, whether the window is open or not, so status, volume, and Open Domine are reachable at any time.
- Background mode starts only if routing is on when the window closes. With routing off there is nothing to keep playing, so Domine stays a normal Dock app (the menu bar item remains), and the Dock icon reopens the window. Once in the background, Domine stays there until the window opens again, even if routing stops (a speaker powers off, or the menu switch turns it off), so auto-start can resume with no window.
- Removing the menu bar item (Command-drag out of the menu bar) while in the background reopens the window, so Domine is never left running with no way to reach it.

## 7. Engine state machine

States: `idle`, `starting`, `running`, `degraded(reason)`, `stopping`, `error(message)`.

- Start requires both devices present and distinct. Otherwise stay `idle` and show why.
- On `kAudioHardwarePropertyDevices` change: if either selected device disappeared, go to `degraded(.monoFallback(missing: side))`: rebuild the aggregate with the remaining speaker only and set the kernel to mono mode, sending (L+R)/2 to both of its channels at the same master volume. When the missing speaker returns (matched by UID), rebuild with both and return to stereo. Fade 50 ms out and in across each rebuild to avoid clicks.
- If both speakers are gone, go to `idle` and restore the previous output (section 4c).
- On `kAudioDevicePropertyDeviceIsAlive` = 0 for a sub-device: same as disappearance.
- Setting a nominal sample rate takes effect asynchronously, so the aggregate can change rate after the kernel was created. Listen for `kAudioDevicePropertyNominalSampleRate` on the aggregate and rebuild when it changes.
- On sleep/wake (`NSWorkspace` notifications): stop before sleep, rebuild after wake.
- Every rebuild creates a fresh tap and aggregate. Never try to patch a live aggregate.
- On quit, always destroy the tap and aggregate. On launch, look for and destroy any stale private aggregate with Domine's UID prefix left by a crash.

## 8. Permissions, signing, entitlements

- `Info.plist`: `NSAudioCaptureUsageDescription` (required for process taps; without it the tap silently returns no audio).
- Hardened runtime on. No sandbox for v1: aggregate device and tap behavior under the App Sandbox has not been verified, and the app is distributed outside the App Store anyway.
- A tap without capture permission returns silence, and there is no reliable API to detect a denial. Detect it best-effort (all-zero tap input for several seconds while another app is known to be playing) and then show a message with a button that opens the Privacy & Security pane.
- TCC ties both grants (audio capture, Accessibility) to the app's designated requirement. An ad-hoc build gets a new requirement on every build; a certificate-signed build keeps it. The saved "capture works" flag is stored with that requirement and reset when it changes. Accessibility is read fresh (`AXIsProcessTrusted`) whenever it is shown. System Settings lists every copy under the name "Domine", so a switched-on entry can belong to another build: when trust is still missing after the user returns from System Settings, Setup offers to reveal the running app in Finder so it can be dragged into the list.

### 8a. Virtual output driver: install and signing

- Install: `scripts/install-driver.sh` builds the Debug driver, copies `Domine.driver` to `/Library/Audio/Plug-Ins/HAL` with `sudo`, sets owner `root:wheel`, and restarts coreaudiod with `sudo killall coreaudiod`. All audio drops for a few seconds while coreaudiod restarts. `scripts/uninstall-driver.sh` removes the bundle and restarts coreaudiod the same way. Both take `--dry-run`.
- coreaudiod loads third-party HAL plug-ins into a sandboxed helper process (`Core Audio Driver Service`). On Apple silicon the bundle must carry a valid code signature. Community drivers built locally (BlackHole from source) load with Apple Development or ad-hoc signatures, so a Developer ID signature is expected to be needed only for distribution and notarization, not for loading. Debug builds sign with Apple Development (team XF5RVRJ6VU). To be confirmed on the first install: if the driver does not appear, check `log show --last 5m --predicate 'process CONTAINS "Core Audio Driver"'` for a signature rejection.
- Release: `scripts/release.sh` builds the driver with Developer ID and the hardened runtime and includes it in the notarized zip next to the app. The app does not install the driver itself in v1; the user runs the install script, or a later installer package does it.
- The driver has no entitlements and no network or file access beyond the host's storage callbacks.

### 8b. Installer

- `scripts/package.sh` turns the output of `release.sh` into `build/release/Domine-<version>.pkg`: one component package puts `Domine.app` in `/Applications`, another puts `Domine.driver` in `/Library/Audio/Plug-Ins/HAL`, both owned by `root:wheel`. `productbuild` combines them with `Installer/distribution.xml` (title Domine, macOS 14.4 minimum, both choices required and not customizable).
- The driver package runs `Installer/scripts/postinstall`, which restarts coreaudiod (`launchctl kickstart -k`, with `killall coreaudiod` as fallback) so the device appears without a reboot. Audio stops for a few seconds.
- The pkg is signed with `productsign` using the Developer ID Installer certificate named in `INSTALLER_IDENTITY`, notarized with the same status check as `release.sh`, stapled, and checked with `pkgutil --check-signature` and `spctl -a -t install`. `release.sh --pkg` runs it as a final step.
- `scripts/uninstall.sh` removes the app and the driver, forgets the `com.ethankawley.Domine.*` receipts, and restarts coreaudiod. It needs sudo and takes `--dry-run`.
### 8c. Updates

- Releases are published as a notarized .pkg on GitHub Releases, tagged `vX.Y.Z`. Updating means downloading and running the installer, which replaces the app and the driver. There is no in-app installer.
- `UpdateChecker` GETs `https://api.github.com/repos/Ethan-Ka/Domine/releases/latest` (no auth, User-Agent "Domine"), compares the tag to `CFBundleShortVersionString` as a semantic version, and takes the first asset ending in .pkg.
- It checks at launch (at most once per 24 hours, timestamp persisted) and from "Check for Updates…" in the app menu, after About. Settings > General has "Check for updates automatically" for the launch check.
- When newer, an alert "Domine X.Y.Z is available." offers "Download Installer" (the .pkg URL, or the release page if there is no .pkg) and "Later". A manual check with nothing newer says "Domine is up to date." Network errors are silent for the automatic check and show a short alert for the manual one.
- It never runs in the unit test host. The network fetch is injected for tests.

## 9. Known risks

- **Two Bluetooth audio links at once.** macOS can hold several A2DP connections, but bandwidth is shared with Wi-Fi on 2.4 GHz and with other Bluetooth devices. Expect occasional dropouts on some Macs. Document this; do not try to fix it in software.
- **Headset profile switch.** If any app opens a Bluetooth speaker's microphone, the speaker drops to the low-quality hands-free profile. Domine must never use a Bluetooth device as an input.
- **Reported latency is unreliable** for Bluetooth. Manual trim is the real fix.
- **Grip stereo pairing left on.** If the Grips are still stereo-paired in the JBL app, only one appears as a Mac output. Detect "only one device named JBL Grip is present" and show a hint to unpair them in the JBL Portable app.
- **Multipoint steal.** A phone connected to one Grip can interrupt it. The Mac sees this as the device going silent or dropping; show the side that stopped.
- **Inactivity power-off.** A Grip that powers down mid-session disappears from Core Audio. Handled by the rebuild logic; the menu shows "Left speaker off" rather than a generic error.
- **More than two Bluetooth links.** Surround mode can hold up to 16 outputs, but every extra A2DP link shares the same radio. Past four Bluetooth speakers dropouts are likely on most Macs; the UI warns (section 13.6) but does not block. Wired, USB and HDMI outputs do not count toward this.
- **Tap edge cases.** Some apps with exclusive or hog-mode output may bypass the tap. Log and document rather than work around.

## 10. Milestones

- **M0, spike (throwaway):** two parts. (a) Baseline: stereo-pair the Grips in the JBL Portable app, connect the Mac to the pair, and note how it sounds and whether the left/right split works from a Mac source. This is the bar Domine has to beat. (b) Unpair them, connect both to the Mac, and run the aggregate + preferred stereo channels `[1, 3]` tool. Proves two Grips can hold two A2DP links to this Mac in sync.
- **M1, device layer:** `AudioHAL` protocol, real wrapper, `DeviceCatalog` with change listeners, fake HAL for tests. Menu shows live output device list.
- **M2, DSP kernel:** C target with channel mapping, gain, delay line, test tone. Full unit test coverage. No Core Audio calls in this target except the `AudioBufferList` type.
- **M3, engine:** tap + private aggregate + IOProc wired to the kernel. Start/stop from the menu. Manual test with two real speakers.
- **M4, resilience:** state machine, disconnect/reconnect, sleep/wake, stale aggregate cleanup.
- **M4b, background features:** mono fallback, restore previous output, background mode with menu bar item, volume keys, app exclusions.
- **M5, polish:** per-pair settings, debug panel, launch at login, permission flow, signing and notarization script.
- **M6, Surround kernel:** `surround.c` behind `DomineSurround.h`: VBAP with the gap and coincident rules, virtual sources, headroom normalisation, width, surround level, rotation, orbit, distance compensation helper, per-speaker effects, gain, delay, mute. Unit tests from section 13.8. The quad kernel stays until M7 is done.
- **M7, Surround engine and UI:** N-speaker aggregate, fallback, settings and migration from quad, Stereo / Surround control, the stage with draggable cards, presets, Add Speaker, controls, the Bluetooth warning. Engine tests against the fake HAL. Ends with the listening test in 13.8.
- **M8, Showcase demo:** `demo.c` behind `DomineDemo.h`, the kernel hook, Play Demo in both modes (Stereo via the temporary surround rebuild), stage dot and status line. Ends with the listening test in 14.7.
- **M9, Linux port:** `linux/` engine on PipeWire behind `linux/src/engine.h`, GTK4 UI with the stage and demo, `make check` self-test (section 15).
- **v2 ideas:** mic-based auto-calibration of the latency offset (play a click on each side, cross-correlate), per-app routing using per-process taps, a true stereo mode where each speaker gets full stereo with a crossfeed amount.

## 11. Quad mode (v2 plan, superseded by section 13)

Superseded by Surround mode (section 13). Kept for history; where the two disagree, section 13 wins.


Quad mode adds rear left and rear right speakers. Positions are indexed 0 FL, 1 FR, 2 RL, 3 RR. Phase 1 (done) is the aggregate, layout, model and UI. Phase 2 is kernel and engine.

### 11.1 Aggregate
- Four output sub-devices in position order. Front left is the main sub-device and the clock (no drift compensation). The other three and the tap get drift compensation at max quality.
- Never force a sample rate. Each Grip stays at its own rate; the aggregate follows the clock device and Core Audio resamples the rest.
- Layout: output offsets are flat channel indexes in sub-device order, one per position. Stereo layout is unchanged (A, B).

### 11.2 Kernel API
- `domine_kernel_process` takes `out_offsets[4]` (-1 for an absent position) instead of two offsets. Each present position gets its signal on all of its channels (mono Grips: both channels).
- `set_gains(pos, gain)`, `set_delay_ms(pos, ms)` take a position index. Delay and gain are atomics per position.
- `set_rear_mode(mode)` and `set_rear_trim(gain)`; `set_effect(id, value)` for Spatial controls (11.6).
- Rear derivation, from stereo input L, R:
  - Mirror: RL = L, RR = R, times rear trim.
  - Matrix: RL = k(L - 0.5R), RR = k(R - 0.5L) with k = 1 / 1.5 so a full-scale out-of-phase input cannot exceed 1.0; times rear trim.
  - Direct: with multichannel input (11.5), map channels to positions.
- Fronts keep their stereo signal in every mode.

### 11.3 Delay model
- One delay per position, never negative. The reference is the slowest speaker (largest latency plus user offset): its delay is 0 and every other position is delayed by the difference. Calibration (11.7) sets the per-position offsets. The stereo signed value maps to this model as two positions.

### 11.4 Mono fallback, generalised
- Any position can be missing. The aggregate is rebuilt with the present positions only. Missing front: the remaining front plays the fronts' mono sum. Missing rear: the front pair is unchanged and the remaining rear plays the rear mono sum. Only one speaker left: it plays the full mono sum. All gone: idle and restore output (4c). Returning speakers (matched by UID) rebuild back to quad. 50 ms fades on every rebuild.

### 11.5 Spatial: multichannel input
- The Domine virtual output driver can advertise a 5.1 or 7.1 layout (`kAudioDevicePropertyPreferredChannelLayout`), so macOS renders spatial content (Apple Music spatial audio, movies) to discrete channels. The process tap then delivers multichannel audio and the kernel maps it: FL, FR direct; SL/BL to RL, SR/BR to RR; center split to both fronts at -3 dB; LFE mixed into the fronts after bass management (low-pass the LFE and the sub-100 Hz content of the others).
- Verify on hardware: whether the tap delivers more than two channels when the default output is multichannel, and which channel order it uses.

### 11.6 Spatial: stereo upmixer
- For stereo sources: mid/side split. Direct sound (mid) stays on the fronts; side and decorrelated ambience go to the rears. Controls: "Spatial amount" (0 to 100%, 0 is mirror trim only) and "Room size" (rear delay plus gentle diffusion, all-pass chain, no allocation on the audio thread).
- UI name is "Spatial". Do not use "Dolby" or "Atmos" anywhere in the app.

### 11.6a Spatial upmixer module
- `Sources/DomineDSP/spatial.c`, `DomineSpatial.h`. Stereo L, R in; rear pair RL, RR out. The fronts are the untouched input. Params: `amount` 0...1, `roomMs` 5...30 (default 15), `highCutHz` 1000...16000 (default 5000). Set through a seqlock; amount and room size smooth over about 10 ms.
- Rear = (1 - amount) * mirror + amount * ambience. Ambience: side S = (L - R) / 2, delayed by room size (RR by 1.13 times that), a different 3-stage all-pass chain per rear (RR polarity inverted), a high shelf of about -4.4 dB above `highCutHz`, gain sqrt(2) so uncorrelated material keeps its level, clamped to +-1 so the rears never exceed full scale.
- Mono input has no side, so the rears fall to silence as amount rises; side-only input appears in the rears. At amount 0 (settled) the output is bit-exact mirror.
- Kernel hook: rear mode `DOMINE_REAR_SPATIAL` (3) with `domine_quad_set_spatial`. Rear trim applies after it. The stereo UI "Spatial amount" and "Room size" map to `amount` and `roomMs`.

### 11.7 Calibration and tuning
- Per-speaker distance (delay) and level calibration. Auto-calibration (section 12) extends to four positions, one click per speaker. Settings persist per set of four speakers (key: the four UIDs sorted).

### 11.8 UI
- Stereo / Quad control. Quad enables when four distinct outputs are assigned. Rear cards open the Choose Speaker sheet. Until phase 2, choosing Quad shows "Quad playback is not ready yet" and routing stays stereo. The status shows "Quad" only once the engine supports it.
- Four A2DP links at once is a real bandwidth risk; test on hardware. Two Grips plus two different speakers is the likely setup.

## 12. Auto-calibration with clicks and the microphone (planned)

Requested by the owner; replaces hand-tuning the delay slider as the normal path. The manual slider stays as an override.

- Input: the Mac's built-in microphone only. Never a Bluetooth input (section 9, headset profile switch). Needs `NSMicrophoneUsageDescription` and its own permission prompt.
- Measurement: the kernel plays a short click (or a chirp, which survives room noise better) on Front Left, waits, then on Front Right. Record both with the mic and cross-correlate each against the emitted signal to get each speaker's arrival time. The difference is the offset; write it to the delay setting.
- Repeat about five times per side and take the median. Reject the run if the correlation peak is weak or the spread between repeats is over 2 ms, and tell the user to move the Mac or lower background noise.
- The Mac's position matters: it measures arrival time at the Mac, not at the listener. The Tuning sheet says to put the Mac where the listener sits.
- The "Play Click Test" button in the Tuning sheet mockup is the entry point. Add an "Auto-calibrate" button next to it.
- Kernel support needed: a one-shot click/chirp generator per side with a sample-accurate start time reported back through an atomic, so the recording can be aligned to the emission.
- Milestone: after M5, before quad mode. Quad mode reuses it to measure all four positions. With Surround mode (section 13) it measures every speaker in the set, one click per speaker, and writes the per-speaker calibration offsets of section 13.4.
