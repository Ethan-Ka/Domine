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
- Speaker care and extras: battery levels, automatic reconnect, keep-alive tone, hints, crossfeed, night mode, delay nudge, pause on exit, rooms export and import, and diagnostics (section 16).

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
- The exclusion list changes at runtime (an excluded app launches or quits, or the list is edited). While routing, the running tap takes the new process list in place by writing its `kAudioTapPropertyDescription`; the tap keeps its UID, so the aggregate keeps playing with no gap. Only if that write fails is the tap rebuilt. Changes are still debounced by about 500 ms.
- When the default output moves (for example to the "Excluded apps play through" device) and the new device already runs at the tap's rate, the tap's format does not change and nothing is rebuilt; the previous default output gets its own rate back. A move that changes the tap's format still rebuilds (section 7).
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
- **Per-speaker volume offset.** Mixed speaker types (for example two Grips and a quieter JBL Go 4) do not play equally loud at the same setting, and a kernel trim can only cut. Each speaker therefore has a hardware volume offset of -12...+12 dB, default 0, stored with its tuning (`PairSettings.leftVolumeOffsetDb` / `rightVolumeOffsetDb` in Stereo, `SurroundSettings.volumeOffsetsDb` by UID in Surround; older records decode to 0). The master volume is the level of a speaker with offset 0. A speaker with an offset is set to the master moved by its offset on its own dB curve (`kAudioDevicePropertyVolumeScalarToDecibels` and `kAudioDevicePropertyVolumeDecibelsToScalar` through `AudioHAL`); a device without that curve is approximated as linear in dB over 48 dB of scalar. The result is clamped to 0...1. When a speaker is at full scale and still short of its offset, the link reports it (`isAtMaximum`) and Sync & Balance shows "At this speaker's maximum"; the other speakers are not cut to make up the difference.
- With offsets, readings are compared as master-equivalent levels (hardware minus offset): the attach rule links everything to the lowest master-equivalent level, and a change made on a speaker sets the master to that speaker's level minus its offset, after which the others follow with their own offsets.
- A speaker without a settable volume takes only a negative offset, as a kernel gain on top of the master (Domine never adds digital gain); its control cannot go above 0 dB and reads "This speaker's volume can't be set from the Mac". Reset in Sync & Balance leaves the offsets alone, since they describe the speakers, not the room.
- Without the virtual output device, volume keys are handled as described in section 4b.

Report the Core Audio latency values (`kAudioDevicePropertyLatency`, `kAudioStreamPropertyLatency`, `kAudioDevicePropertySafetyOffset`) in a debug panel, and use their difference as the initial default offset. Bluetooth devices often report these inaccurately, so the manual slider always wins.

Sample rate: never set the nominal sample rate (`kAudioDevicePropertyNominalSampleRate`) of a Bluetooth speaker. Each speaker keeps the rate it reports, which follows its Bluetooth codec (a freshly connected JBL Grip reports 44.1 kHz, the only rate it offers). Reason: on hardware, Grips that had been forced to 48 kHz kept reporting 48 kHz while their AAC encoder still ran at 44.1 kHz with no conversion, so everything, even plain macOS playback with no Domine, played about 8% slow and 1.5 semitones low until the speaker was power-cycled. The aggregate runs at the main sub-device's (Device A's) rate, and the kernel, delay, tone, and click use that rate. If Device B reports a different rate, log a warning and let the aggregate's drift compensation convert it. The tap follows the system default output's rate, so when the default output is not Bluetooth (for example the built-in speakers) and supports Device A's rate, Domine sets it to that rate while running and restores its previous rate on stop. If the default output then moves to a device already at the tap's rate, nothing is rebuilt and the device Domine changed gets its previous rate back right away. Otherwise the tap's drift compensation converts it.

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
- "Start routing when speakers connect" works in background mode, so with launch at login on, Domine starts on its own when the Grips power up.
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
- **Grip stereo pairing left on.** If the Grips are still stereo-paired in the JBL app, only one appears as a Mac output. Detect "only one device named JBL Grip is present" and show a hint to unpair them in the JBL Portable app (section 16.4).
- **Multipoint steal.** A phone connected to one Grip can interrupt it. The Mac sees this as the device going silent or dropping; show the side that stopped (section 16.4).
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
- Repeat about five times per side and take the median. A repeat counts only when both correlation peaks are at least 10 times the window's median absolute correlation; with fewer than 3 such repeats the run fails, and the noise check below names the cause. Outliers (a reflection, Bluetooth jitter, a misdetected peak) must not fail the run: repeats within a tolerance of the median offset are kept (1.5 ms or 3 x the median absolute deviation, whichever is larger, capped at 3 ms), and the result is the median of the kept repeats. The run fails with "Results varied. Move the Mac and try again." only when fewer than 3 repeats, or fewer than 60% of the detected ones, are kept.
- Chirps always play at full `DOMINE_CHIRP_AMPLITUDE` on every speaker: they bypass the delay line, the trims, balance, master volume share and distance gain, so a speaker turned down is never too soft for the mic, and every speaker is measured at the same drive level.
- Level: the same captures also measure how loud each speaker arrives. Its level is the height of its matched-filter (correlation) peak, median over the kept repeats. That height is proportional to the chirp's amplitude at the mic, counts only energy in the chirp's band and only the direct arrival, so steady noise and later reflections barely move it. Every measured speaker is then cut to the quietest one: trim_i = quietest / level_i, so the quietest gets 1 and nothing is boosted, floored at 0.1 (-20 dB). A speaker whose capture failed keeps its trim. In Stereo the two levels set the balance (the louder side is cut), and success reads "Right was 12 ms late. Delay and balance set." (or "Speakers are in sync. Delay and balance set.").
- Noise check: before the chirps of every run the mic records 0.7 s of the room with program audio muted (the first 0.15 s, the mute fade, is skipped). That noise goes through the same matched filters as the chirps, so its floor (RMS of the filter output) is in the same band and units as the levels, and each speaker's SNR is 20 log10(level / floor). The threshold is 20 dB: below it the noise is over 10% of the chirp peak, the level reading can be off by about 1 dB, and noise peaks start to rival the chirp (the detector needs a peak 10 times the median, about 17 dB over the RMS). When the quieter speaker is under 20 dB and the louder one is under 30 dB, or when neither chirp could be detected at all, the run fails with "Too much background noise. Make the room quieter and try again." When one speaker is clear (30 dB or more, or its chirp detected in at least 3 repeats) and the other is under 20 dB or undetected, that speaker is to blame: "JBL Go 4 (7146) was too quiet to measure. Turn it up and try again." (device name and UID suffix). The noise floor and each speaker's SNR are logged.
- Diagnostics: each pair logs one summary line (kept and detected repeats, result); every repeat's offset and peak-to-median ratios are logged only when that pair fails (Calibration category). Recordings are saved only for a failed run, as 16-bit PCM mono WAV in `~/Library/Logs/Domine/Calibration/calibration-<timestamp>-<pair>.wav` (pair is "stereo" or "pair1"...), one per pair of that run, written off the main actor. Only the most recent failed run is kept: the folder is emptied before writing, and emptied when a later run succeeds; a cancelled run leaves it. The folder never exceeds 3 MB: if the run would, only the pairs that failed are kept, then downsampled to 22.05 kHz, then the earliest dropped until it fits. `scripts/uninstall.sh` removes it with `~/Library/Logs/Domine`.
- The Mac's position matters: it measures arrival time at the Mac, not at the listener. The Tuning sheet says to put the Mac where the listener sits.
- The "Play Click Test" button in the Tuning sheet mockup is the entry point. Add an "Auto-calibrate" button next to it.
- Kernel support needed: a one-shot click/chirp generator per side with a sample-accurate start time reported back through an atomic, so the recording can be aligned to the emission.
- Milestone: after M5, before quad mode. Quad mode reuses it to measure all four positions. With Surround mode (section 13) it measures every speaker in the set and writes the per-speaker calibration offsets of section 13.4, as below.

### 12.1 Surround: a ring of pairs
- Used in Surround routing with two or more present speakers s0...s(N-1) (list order); otherwise the stereo procedure above runs. Same entry points and enable rules as Stereo: the Auto-calibrate button next to the click test in Sync & Balance (built-in microphone present, no run in progress) and the status menu item.
- N runs of the stereo measurement, one per pair (s0, s1), (s1, s2), ..., (s(N-1), s0). Run k sets `domine_surround_set_calibration_pair(s, k, k+1 mod N)` (kernel indexes): s_k plays the rising chirp, s(k+1) the falling one, every other speaker is silent, and the chirps bypass the delay line, trim and distance gain (full amplitude). Each run gives d_k = arrival(s(k+1)) - arrival(s_k) in ms. The pair is turned off after every run, on cancel, and on every engine stop.
- Closure: around the ring the d_k must sum to 0. If |sum d_k| > 3 ms times the number of pairs (Bluetooth latency wobbles by a few ms per measurement, and mixed speaker models can be 80 ms or more apart) the run fails with "Results varied. Move the Mac and try again." Otherwise sum / N is subtracted from each d_k, arrival(s0) = 0, arrival(s(k+1)) = arrival(s_k) + d_k, and offset_i = max(arrival) - arrival_i, clamped to 0...300 ms. All offsets are written at once and the set is marked timing measured (13.4).
- Example: arrivals 0, 12, -5, 30 ms give d = 12, -17, 35, -30 and offsets 30, 18, 35, 0.
- Any failed pair stops the run and leaves every offset unchanged. The message names both speakers of that pair (card title plus UID suffix, since every speaker may be called "JBL Grip") and the reason.
- Levels: run k also gives the level difference e_k = level(s(k+1)) / level(s_k) in dB. These are chained around the ring like the arrivals (the closure error is spread evenly, never fatal), then every speaker is cut to the quietest as in section 12, all trims are written at once, and the set is marked level measured (13.4). If any pair returned no level, trims are left unchanged and the set is not marked.
- Progress reads "Measuring pair 2 of 4…"; success "Delays and levels set for 4 speakers." ("Delays set for 4 speakers." when levels were not measured). Cancel (closing the sheet) works between and during pairs.

## 13. Surround mode (N speakers)

Replaces quad mode (section 11) as the multi-speaker plan. The owner asked for "three or more speakers, unlimited, set up like a surround system no matter the number, and you can move them around". Surround mode takes 2 to 16 speakers (two can sit front and back, with the ambience on the rear one) (`DOMINE_SURROUND_MAX_SPEAKERS`, `SurroundSpeaker.maxCount`), places each at an angle and distance around the listener, and pans the stereo tap across them. Stereo mode (two speakers, `domine_kernel_*`) is unchanged.

Naming: the owner called it "Dolby Atmos 8D". Section 11.6 forbids "Dolby" and "Atmos" anywhere in the app, and "8D" is not used either. The mode is "Surround", the rotating effect is "Orbit".

Kernel contract: `Sources/DomineDSP/include/DomineSurround.h`. Model: `Sources/Domine/State/SurroundSpeaker.swift`.

### 13.1 Model
- A speaker is a `SurroundSpeaker`: device UID (never an `AudioObjectID`), azimuth, distance. Azimuth in degrees, 0 straight ahead of the listener, positive clockwise seen from above (to the right), wrapped to (-180, 180]. Distance in metres, 0.5 to 10, default 2.
- The set is an ordered list. List order is speaker index everywhere: kernel index, aggregate sub-device order, card order in the Sync & Balance sheet. New speakers append; the nth speaker added gets `SurroundSpeaker.defaultAzimuth(forIndex:)` (-30, 30, -110, 110, 0, 180, -70, 70, ...).
- Settings key: `Domine.surround.<UIDs sorted, joined by |>`. Any order of the same speakers finds the same record. The record holds each speaker's azimuth, distance, trim, calibration offset (ms) and effects (EQ, bass, compressor, as `PairSettings.SideEffects`), plus width, surround level, orbit speed, rotation, spatial amount and room size. The last used set is stored as `Domine.lastSurroundUIDs`. Adding or removing a speaker changes the key: the new record starts from the old one (speakers that stay keep everything) and the new speaker gets its default azimuth and 2 m.
- Same name rule as stereo: two "JBL Grip" entries are told apart by the UID suffix, never by name.
- Presets (Presets menu, 13.6). A preset assigns azimuths only; distances, trims and effects stay. Speakers keep their clockwise order: the current azimuths are sorted and mapped onto the preset's azimuths, sorted the same way.

| Preset | Speakers | Azimuths |
|---|---|---|
| Quad | 4 | -30, 30, -110, 110 |
| 5 speaker | 5 | -30, 0, 30, -110, 110 |
| 7 speaker | 7 | -30, 0, 30, -90, 90, -150, 150 |
| Ring | any N | evenly spaced: -180 + 360 (i + 0.5) / N, so 4 gives -135, -45, 45, 135 |

  Quad, 5 speaker and 7 speaker are enabled only when the set has exactly that many speakers. Ring is always enabled.

### 13.2 Aggregate
- Same rules as 11.1 with N sub-devices in list order. The first present speaker is the main sub-device and the clock (no drift compensation). Every other speaker and every tap gets drift compensation at max quality.
- Never force a sample rate (section 4a). The aggregate runs at the clock device's rate.
- Private, rebuilt from scratch on every change of the set, of a speaker's presence, or of the clock's rate. Never mutated while running (section 7).
- Output offsets: one flat channel index per speaker in list order, read from `kAudioDevicePropertyStreamConfiguration` after polling until the output channel count equals the sum of the present sub-devices. A speaker that is absent from this build gets `DOMINE_NO_DEVICE`. Passed with `domine_surround_set_layout` before `AudioDeviceStart`; the IOProc is `domine_surround_ioproc`.
- The kernel writes each speaker's signal on offset and offset + 1 (mono Grips need both). An output with fewer than two output channels is not offered in Surround mode, since offset + 1 would land on the next speaker.
- Never open a Bluetooth speaker for input; the input rules of section 5 apply unchanged.
- Volume (4a) generalises: every speaker in the set that has a settable hardware volume is linked. A change on any one (from its buttons) is applied to all others, with the same suppression window. With the virtual output installed its volume is the master, as in stereo.

### 13.3 Rendering
The kernel turns the stereo tap into a few virtual sources and pans each one over the speakers.

- Sources: 0 is L at -width, 1 is R at +width, 2 and 3 are the ambience pair from the spatial upmixer (`DomineSpatial.h`, 11.6a) at -110 and +110 (`DOMINE_SURROUND_REAR_AZ`) times surround level, 4 and up are demo voices (section 14). Ambience sources are used whenever 2 or more speakers are present (stereo routing's demo sets surround level 0).
- Every source azimuth is offset by rotation plus the orbit phase before panning.
- Panning: 2D pairwise VBAP (`domine_surround_vbap`). A source pans between the two adjacent present speakers that enclose it. If their arc is under 180 degrees the gains solve the 2D VBAP equation and are normalised to unit power. One speaker gets gain 1.
- Gap rule: if the enclosing arc is 180 degrees or wider (behind a front-only pair, or one side of a lopsided layout) VBAP would flip sign, so the gains are constant-power by angle fraction across the arc: cos(f pi/2) and sin(f pi/2), where f is the source's fraction of the arc.
- Coincident rule: speakers within 0.5 degrees (`DOMINE_SURROUND_COINCIDENT_DEG`) count as one position and share its gain equally by power (1/sqrt(k) each for k speakers). A source exactly on a speaker gives that speaker (or its group) the whole source.
- Headroom normalisation: each source is unit power, but two sources can land on the same speaker (L and R both near one speaker in a 3-speaker layout, or ambience on a front speaker). For each speaker the kernel sums the absolute gains of all program sources (ambience counted at its surround level, and L and R including their rear fill above level 1); if the largest sum exceeds 1, every program gain is scaled by 1 / that sum. Since L, R and ambience are each within +-1, no speaker exceeds the larger input peak. This keeps the 4d rule that the kernel never adds gain, and it gives the two exact cases: 2 speakers at -width and +width play L and R bit for bit; 1 speaker plays (L + R) / 2 bit for bit. Demo voices are not part of this sum (section 14.3).
- Width: azimuth of the L and R sources, 10 to 90 degrees, default 30. Narrow puts the stereo image in front, wide wraps it toward the sides.
- Surround level: 0 to 2, default 0.7. Up to 1 it scales the ambience sources. 0 means only L and R play, panned over the speakers that enclose them. Above 1 the ambience gains keep scaling with the level, and with 2 or more speakers L and R also play at -110 and +110 times (level - 1) (rear fill), so near-mono music, which has little ambience, still reaches the rear speakers. Headroom normalisation then keeps every speaker within full scale, so the front speakers may get a little quieter.
- Rotation: static offset of the whole field, -180 to 180, default 0. Lets the user face another way without dragging every speaker.
- Orbit: continuous rotation in degrees per second, clamped to +-720 in the kernel (the UI offers -90 to 90). 0 stops the field where it is; "Reset" returns the phase to 0. Orbit is a listening effect, not a correction, and is off by default.
- Pan gains ramp from the old values over one process call when the layout, width, rotation or orbit changes (no zipper, no click). Dragging a card updates the kernel live.
- After panning, each speaker runs its own chain from section 5a: EQ, bass, compressor, then trim gain, then delay. Then mute (50 ms fade) and the peak meter (`domine_surround_peak`).
- Multi-tap input (per-app volume, section 5a) works as in the quad kernel through `domine_surround_set_tap_layout` and `_tap_gain`.

### 13.4 Distance compensation
- `domine_surround_distance_comp` turns distances into delay and gain so every speaker's sound arrives at the listener at the same time and level. The farthest speaker is the reference (delay 0, gain 1). Speaker i gets delay (dmax - d_i) / 343 m/s and gain d_i / dmax (inverse distance law). Example: speakers at 2 m and 3 m, the 2 m one gets 2.915 ms and 0.667.
- Combined with calibration (11.3, section 12): total delay_i = distance delay_i + calibration offset_i, then the smallest total over the present speakers is subtracted so it is 0 and none is negative, clamped to `DOMINE_MAX_DELAY_MS` (300). Total gain_i = trim_i times distance gain_i, set with `domine_surround_set_gain` (never above 1). While the set is marked level measured, total gain_i = trim_i only: measured trims already hold each speaker's whole level difference at the Mac, distance included.
- The calibration offset is the per-speaker Bluetooth latency correction (manual in the Sync & Balance sheet, or measured by section 12). Distance is geometry only. They stay separate in settings so moving a card does not lose a measured latency.
- Measured vs unmeasured: offsets measured with the microphone (12.1) already hold each speaker's whole arrival difference at the Mac, acoustic travel included, so adding distance delay would count travel twice. While the set is marked timing measured, total delay_i = calibration offset_i only (normalised so the smallest over the present speakers is 0, clamped to 300); distance still sets gain. Unmeasured, the rule above applies. Manual offset edits keep the mark; Reset in Sync & Balance clears every offset and the mark; adding or removing a speaker clears the mark. The level-measured mark is kept and cleared under the same rules (manual trim edits keep it). Surround Sync & Balance says "Timing and levels measured with the microphone." with both marks, "Timing measured with the microphone; distances set level only." with timing only, "Levels measured with the microphone; distances set timing only." with levels only, and nothing with neither. Distance still sets delay unless timing is measured.
- Recomputed on the main actor whenever a distance, trim, offset or speaker presence changes.

### 13.5 Fallback
- Any speaker missing (device gone or `kAudioDevicePropertyDeviceIsAlive` 0): state `degraded(.surroundMissing(uids))`. Rebuild the aggregate with the present speakers only. The kernel keeps the full layout (indexes, effects and settings stay put) and the missing speaker gets `DOMINE_NO_DEVICE`, so VBAP re-pans its share to its neighbours. If the clock speaker went, the next present speaker in list order is the clock.
- Two present: the surround kernel continues with two speakers (gap rule covers the open side). Ambience stays on with two present speakers.
- One present: it plays the mono sum (L + R) / 2 on both channels (13.3 headroom rule gives this exactly). Status "Mono fallback".
- None present: `idle`, restore the previous output (4c).
- A returning speaker (matched by UID) rebuilds back into the set at its saved position. 50 ms fades out and in across every rebuild.
- Banner: "<name> <UID suffix> disconnected. The other speakers cover its position until it reconnects." With several missing, "2 speakers disconnected. ..." Missing cards stay on the stage in the error state.

### 13.6 UI
- The toolbar's Stereo / Quad control becomes **Stereo / Surround**. Surround is enabled once at least two distinct outputs are available (connected, not hidden by DeviceCatalog). First switch: the set starts with the current stereo pair at -30 and +30 (swap applied) and nothing else (the Mac's speakers or AirPods are never added on their own; more speakers come from "Add Speaker..."); later switches restore `Domine.lastSurroundUIDs`.
- Stage: a top-down room with the listener in the centre (person symbol, not the Mac icon), "FRONT" at the top, faint rings every metre. Scale: the farthest speaker sits at about 85% of the stage radius, never less than a 4 m radius. Each speaker is a card drawn at its azimuth and distance, with a line from the listener.
- Drag a card to move it: azimuth and distance follow the pointer, azimuth snaps to 5 degrees and distance to 0.1 m; holding Option disables snapping. Distance clamps to 0.5 to 10 m. The kernel follows live; settings save on drag end. A click without movement opens the Choose Speaker sheet for that card.
- Card contents as in stereo (device name, UID suffix, status line, 16-segment meter), but the side tag (L, R, L+R) is replaced by an angle label like "-30°" (with "2.0 m" beside it while dragging). Fallback cards show "L+R" as in stereo.
- "Add Speaker..." (bottom bar) opens the Choose Speaker sheet filtered to outputs not in the set. Disabled at 16 speakers. Card context menu: "Choose Speaker...", "Remove Speaker". With fewer than 2 connected speakers in the set, routing falls back to Stereo on the pair.
- Presets menu (13.1): Front and Back (2 speakers: 0 and 180), Quad, 5 speaker, 7 speaker, Ring.
- Controls in a row under the stage: Width (slider, 10° to 90°), Surround level (slider, 0 to 200%), Orbit speed (slider, -90 to 90°/s, centre is "Off", readout like "20°/s clockwise"), Rotation (slider, -180° to 180°, with Reset). Master volume, Play Demo (section 14) and "Sync & Balance..." stay in the bottom bar; Test L / Test R are hidden in Surround; in their place "Test Speakers" plays the chime on each connected speaker of the set in list order (1.5 s each, 250 ms apart), and each card reads "Playing test tone" while its chime sounds. The card context menu's "Play Test Tone" plays one speaker.
- The stage draws what the sliders do, under the cards, on the 2 m ring: a band between an "L" and an "R" dot at -width and +width (Width), two dots at -110 and +110 joined by a dashed arc across the back whose strength follows the Surround level (hidden at 0), all turned by Rotation and spun by Orbit in time with the audio: while surround routes, the drawing uses the kernel's phase (`domine_surround_orbit_phase`) moved back by orbit rate times the output delay (the longest of each present speaker's delay plus its reported latency); otherwise it runs its own clock, which restarts on Reset and at speed 0 like the kernel's. Hidden while the demo plays.
- Sound sheet in Surround: a "Mono" checkbox, off by default and saved with the set, plays 0.5 L + 0.5 R in place of both L and R before panning and the upmixer (`domine_surround_set_mono`), so every speaker plays the whole mix.
- Sync & Balance in Surround: one row per speaker with calibration offset (ms) and trim, plus effects per speaker. Distance comes from the stage, not from this sheet.
- Warning: with more than 4 Bluetooth speakers in the set (transport type `kAudioDeviceTransportTypeBluetooth`, read through `AudioHAL`), a line under the toolbar: "More than 4 Bluetooth speakers can drop out. Wired outputs are not affected." It does not block (sections 9, 11.8).
- Status line: "Surround, 5 speakers", or "Surround, 4 of 5 speakers" when degraded.

### 13.7 Migration from quad settings
- Runs once at launch when a quad set is saved (`lastLeftUID`, `lastRightUID`, `lastRearLeftUID`, `lastRearRightUID` all set) and no surround record exists for those four UIDs.
- Map positions to azimuths: FL -30, FR 30, RL -110, RR 110, distance 2 m. Use the speaker that actually played left (swap applied) as FL.
- Keep effects: fronts take their effects from the pair settings, rears from `QuadSettings.rearEffects(...)` (so linked rears get the fronts' effects). Trims and delay offsets carry over as per-speaker trim and calibration offset; the stereo signed delay becomes two non-negative offsets (11.3).
- Rear trim becomes surround level. Spatial amount and room size carry over; rear mode Mirror becomes spatial amount 0 (11.6a: amount 0 is exact mirror); Matrix has no equivalent and becomes the default amount 0.6.
- `routingMode` quad becomes surround. Rooms that hold rear UIDs migrate the same way.
- Old `Domine.quad.*` keys stay in place for one release so a downgrade still works. Migration is idempotent.

### 13.8 Tests and listening test
Kernel tests (exact expected values, known input buffers):
- VBAP: speakers at -30 and 30, source at 0 gives 1/sqrt(2) each; source on a speaker gives 1 there and 0 elsewhere; front pair with source at 180 uses the gap rule (cos(pi/4) each); two coincident speakers get 1/sqrt(2) each; sum of squares 1 in every case; an absent speaker gets 0.
- Bit exactness: 2 speakers at -30 and 30 with width 30 output L and R bit for bit; 1 speaker outputs (L + R) / 2 bit for bit.
- Headroom: random full-scale input on 3, 5 and 16 speaker layouts never exceeds the larger input peak.
- Rotation by 360 equals no rotation. Orbit phase after a known number of frames matches rate times time. A layout change ramps with no step larger than the ramp allows.
- Distance helper: 2 m and 3 m give 2.915 ms and 0.667; non-positive distances count as 1 m.
- Absent speaker: its share moves to its neighbours and its channels are zeroed.
Engine tests against the fake HAL: N sub-devices in list order, first present is clock, drift keys on the rest; removal rebuilds without the speaker and with `DOMINE_NO_DEVICE` in the layout; one left gives mono; none gives idle and restore; the settings key string; migration output for a saved quad set.

Listening test (after M7; Claude stops and asks the user): with four speakers on the Quad preset, play a stereo track with a clear left/right mix. Expected: the front pair sounds like normal stereo, the rears add room sound but no lead vocal. Drag the front left card to -90: the left part of the mix moves to the side. Set Orbit speed to 30°/s: the whole mix turns slowly around the room, one revolution every 12 s, with no clicks or level jumps. Switch off one rear speaker: a short gap, then its ambience comes from the neighbours; switch it back on and it rejoins.

## 14. Showcase demo

### 14.1 Purpose
A built-in piece (47 s for two speakers, 47 to 51 s in general) the user plays to hear and feel what Domine does: where each speaker is, the left/right split, and sound moving around the room. It is an original piece in the spirit of a giant-screen theatre sound-system preshow, without a narrator: a dark, quiet room, precise sounds that place each speaker, sounds that travel and accelerate, a huge slowly building chord, a moment of silence, and one massive clean impact with a long tail. Precision and scale, not dance music. It imitates no existing preshow audio. Generated live in the kernel for the current speaker set (`Sources/DomineDSP/include/DomineDemo.h`), no audio files.

### 14.2 Timeline
Exactly as `DomineDemo.h`. Grid: 120 BPM (beat 0.5 s, bar 2 s); every section starts on a downbeat and a drone carries across the sections. Key: D natural minor, equal temperament from A4 = 440 Hz, tonic D2 = 73.42 Hz (where Grips start to work); every pitched sound uses only scale tones. R is the Calibration length: 2 s of ticks plus the roll call rounded up to whole bars (6 s for N <= 4 and N > 8, 8 s for N = 5 and 6, 10 s for N = 7 and 8). Total length R + 41 s, reported by `domine_demo_length`. `DOMINE_DEMO_LENGTH_S` (51) is the longest.

| Time (s) | Section (value, UI title) | What plays |
|---|---|---|
| 0 to R | ROLL_CALL (1, "Calibration") | Soft A6 ticks on every beat, a dark D minor drone fading in. From 2 s the roll call, clockwise from the speaker nearest hard left, each kick exactly on its speaker's azimuth, exactly one hit per speaker per round: N <= 2 a double hit per speaker ("da-dum", 0.25 s apart, second louder) every 2 beats, 4 slots; 3 to 8 speakers one hit per beat, two rounds; more than 8 one hit per half beat, one round. |
| R to R+6 | PING_PONG (2, "Left and right") | Kicks alternate -90 and +90, first on the left: quarters for a bar, eighths for a bar, sixteenths for 3 beats, over a D2 sub pulse on every beat. |
| R+6 to R+12 | SWEEP (7, "Sweep") | A tone plus band-passed noise flies across the room 6 times clockwise from -90 (front, back, front...), each pass faster (2, 1.5, 1, 0.75, 0.5, 0.25 s) and gliding one scale step up (D3 F3 G3 A3 C4 D4 F4, starting and ending on scale tones), with a Doppler-like bend in each pass (above pitch approaching, falling through it at the middle, below it receding). Ends at +90. |
| R+12 to R+22 | ORBIT (3, "Orbit") | A smooth bass (saws at the root and an octave up plus a root sine, low-pass wobbling 250 to 700 Hz at 1 Hz) playing Dm, Bb, F, C, Dm, one chord per bar (roots D2, Bb1, F2, C2, D2, the drone follows), enters at +90 where the sweep ended and circles clockwise, 0.25 to 0.6 turns per second. A kick every 2 beats on its azimuth; off-beat hats on the mirror path. |
| R+22 to R+32 | SWELL (4, "Swell") | The drone opens into a brass-like chord: 12 detuned saws voiced over three octaves (D2 to D5 for Dm) through a slowly opening low-pass (280 Hz to 4.5 kHz), split across two voices that spread from the centre to -90 and +90 and toward every speaker. One chord per bar: Dm, Bb, Gm, Asus4, A. A slow crescendo, a deep sub on the chord root, and a timpani-like tom on each chord change. The bass follows and fades out over 6 s. Bright pings on chord tones sweep across the top; a noise riser climbs through the last 2 bars. Everything cuts with a 30 ms fade at R+32. |
| R+32 to R+33 | SILENCE (8, "Silence") | Every voice exactly 0. |
| R+33 to R+41 | DROP (5, "Impact") | A clean kick (A3 to D2) and a saturated sub boom (A1 to D1) on every speaker, a wide noise burst whose low-pass falls from 10 kHz to 200 Hz, and a big D minor chord (root, fifth, octave, minor third on top) sustaining with a slow fade, all decaying to exactly 0. Then FINISHED (6). |

Kick: saturated sine falling A3 to D2 (220 to 73.4 Hz) (tau 30 ms), amplitude exp(-t / 90 ms), 1 ms attack, 20 ms cosine fade to 0 at 220 ms, plus a beater layer (D7 sine and a noise tick) so it reads clearly on small speakers. Kicks duck the drone and the bass. Two kick voices alternate so a tail is never cut. Deterministic: the same speakers and sample rate give the same samples.

### 14.3 Rendering
- The demo produces up to `DOMINE_DEMO_VOICES` (8) voices per frame, each a mono sample with an azimuth and an omni amount. The surround kernel adds them as sources 4 and up, panned with the same `domine_surround_vbap` over the present speakers, then blended toward equal power on every speaker: g_k = (1 - omni) vbap_k + omni / sqrt(N).
- Each voice peaks within 0.8 and the absolute values of all voices together within 1.0 (a safety limiter on the voice sum enforces it), so no headroom scaling is needed; demo voices are left out of the 13.3 sum.
- The demo goes through each speaker's effects, trim, distance delay and gain, calibration delay and mute, like program audio, so it shows the user's real setup.
- Program audio crossfades out over 50 ms when the demo starts and back in over 50 ms when it stops or finishes (`domine_surround_set_demo`).
- While the demo plays the engine sets rotation 0 and resets and stops the orbit, so each roll-call kick lands on its speaker; the user's rotation and orbit return when the demo ends. Width and surround level do not affect the demo.

### 14.4 Behaviour
- "Play Demo" button in the bottom bar, in Stereo and Surround modes. Enabled while routing with at least 2 speakers present. While playing it reads "Stop Demo". The demo stops on its own at `domine_demo_length` (47 s for two speakers).
- A second "Play Demo" / "Stop Demo" button sits in the Sync & Balance sheet, on its own row below the sync and balance controls, near Play Click Test. While the demo plays, a caption beside it shows the current section ("Calibration", "Left and right", "Sweep", "Orbit", "Swell", "Silence", "Impact"). Both buttons drive the same demo and show the same state. This lets the user tune delay and balance while hearing the roll call and ping-pong.
- Surround mode: `domine_surround_set_demo(s, 1)`. No rebuild.
- Stereo mode: the stereo kernel (`domine_kernel_*`) keeps normal playback and has no demo hook. Play Demo rebuilds the engine once with the surround kernel and two speakers, Device A at -30 and Device B at +30 (swap applied, so the speaker playing left sits at -30), with the pair's effects, trims and delay. The stereo kernel fades out over 50 ms, the rebuild happens, and the surround kernel starts faded out (`domine_surround_start_faded_out`), fades in over 50 ms, then the demo starts. When the demo finishes or is stopped, the same in reverse back to the stereo kernel. With 2 speakers and no demo the surround kernel plays L and R bit for bit, so program audio during the switch is unchanged apart from the rebuild gap. Decision: the surround path is used instead of adding a demo hook to the stereo kernel, so there is one demo implementation.
- A device change, sleep, or routing stop during the demo stops it; Stereo mode then rebuilds with the stereo kernel as usual.
- Master volume is not changed by the demo. It plays at the user's volume.

### 14.5 UI
- A dot moves on the stage at the demo azimuth from `domine_surround_demo_status`, polled at 30 Hz with the meters. It sits at the average speaker distance. When omni is high (Swell, Impact) the dot widens into a ring around the listener. In Stereo mode the stage draws the dot between and around the two cards the same way.
- The status line shows the section: "Demo: Calibration" (1), "Demo: Left and right" (2), "Demo: Sweep" (7), "Demo: Orbit" (3), "Demo: Swell" (4), "Demo: Silence" (8), "Demo: Impact" (5), by `DOMINE_DEMO_SECTION_*` value. Idle (0) and finished (6) show the normal status.
- Cards light up through their meters as usual; no extra animation per card.

### 14.6 Bass on the Grip (honest note)
JBL Grips roll off below about 70 to 80 Hz (section 1a: 70 Hz at -6 dB, one small driver). The bass roots (Bb1 to F2, 58 to 87 Hz) sit at the edge of what the Grip reproduces. The bass is built so it still works: the saws' harmonics carry the pitch (the ear fills in the missing fundamental), the kick's pitch sweep runs 220 to 73 Hz (A3 to D2), and the D7 beater gives each hit a clear position. The chord spans D2 to D5. Very low bass is hard to place anyway; position comes from the harmonics and the click. On Grips the "feel" is punch in the 100 to 200 Hz range, not sub bass. With larger speakers or a subwoofer in the set the sub content is heard and felt. The UI does not claim more than this.

### 14.7 Levels and tests
- Levels: one voice at most 0.8 (about -2 dBFS), all voices at most 1.0. The Impact at omni 1 gives each of N speakers 1/sqrt(N) of the kick, so its acoustic power equals one speaker at full.
- Unit tests: determinism (two runs give identical samples); section boundaries at the exact frames for 44.1 and 48 kHz; length per speaker count; roll-call onsets on the grid and on each speaker's azimuth, in clockwise order from the speaker nearest -90, double hits for N = 2, two rounds for N = 8, one round for N = 9; ping-pong alternates from -90 with gaps 0.5, 0.25, 0.125 s; sweep travels 1080 degrees clockwise with the Doppler bend; orbit starts at +90 and turns 4.25 times; Silence exactly 0; one omni Impact kick; per-voice and summed peaks within 0.8 and 1.0; silent and FINISHED from `domine_demo_length` on; kernel crossfade takes 50 ms each way and program audio is bit exact again after it.
- Engine tests against the fake HAL: Play Demo in Stereo rebuilds with the surround kernel at -30 and +30 and back afterwards; a device removal during the demo stops it.
- Listening test (after M8): press Play Demo. Expected: a quiet room with soft ticks, then a kick from each speaker in turn going clockwise from the left (with two Grips: "da-dum" left, "da-dum" right, twice); left/right kicks over a sub pulse that speed up; a tone that flies across the room faster and faster, bending in pitch as it passes; a smooth bass circling with kicks; a brass-like chord that climbs Dm, Bb, Gm, A with a timpani hit on each change, grows and spreads to every speaker, with a riser at the end; a moment of true silence; one big clean impact and D minor chord on every speaker that rings out slowly to silence. No clicks at section changes or at the start or end; program audio returns smoothly.

## 15. Linux port

### 15.1 Goals
- Same routing idea on PipeWire: create a virtual sink named "Domine", make it the default sink, capture its monitor, run the surround kernel, and play one stream per speaker to that speaker's sink. On stop, restore the previous default sink (remember it at start, like 4c).
- Sinks are keyed by `node.name` (stable across reconnects, for Bluetooth it contains the device address), never by the numeric node id. `node.description` is the label. Domine's own sink is never listed.
- Playback streams target their sink by `node.name` and must not be moved to another sink when theirs disappears (`node.dont-reconnect`); a missing sink is handled like 13.5.
- Never open a Bluetooth source node (same headset profile risk as section 9).
- Same render kernel: the Makefile compiles every `Sources/DomineDSP/*.c` unchanged. The Core Audio types it needs (`AudioBufferList`, `AudioTimeStamp`, `OSStatus`, `AudioObjectID`) come from a small shim in `linux/compat/CoreAudio/`. So `Sources/DomineDSP/` must stay portable C11: no Apple headers beyond `CoreAudioTypes.h` and `AudioHardwareBase.h`, no Apple-only APIs. The kernel runs on the PipeWire real-time thread with the rules of section 5.
- Stereo on Linux is the surround kernel with two speakers at -30 and +30, which is bit exact (13.3); there is no separate stereo kernel path.
- GTK4 UI with the same stage as 13.6 (listener in the centre, draggable cards, snapping, Presets, Width, Surround level, Orbit speed, Rotation), master volume, and Play Demo with the moving dot and section label (section 14).
- The UI talks to audio only through `linux/src/engine.h` (`dl_engine_*`). Master volume is a kernel gain on every speaker.
- Settings keyed as in 13.1 with `node.name` in place of the UID, stored under `$XDG_CONFIG_HOME/domine/`.

### 15.2 Non-goals (first version)
- No Bluetooth hardware volume linking (4a); master volume is digital in the kernel.
- No auto-calibration (section 12). Manual offsets only.
- No app exclusions, per-app volume, volume key handling, or virtual driver install. PipeWire's own sink handles volume keys for the "Domine" sink if the desktop shows it.

### 15.3 Build and test
- Needs the `libpipewire-0.3` and `gtk4` development packages.
- `cd linux && make` builds `./domine`.
- `cd linux && make check` builds and runs the headless engine self-test (no audio hardware needed).
- The macOS build is not affected; `linux/` is not part of `project.yml`.

## 16. Speaker care and extras

### 16.1 Battery
- Read through `IOBluetoothDevice` using the KVC keys `batteryPercentSingle` and `batteryPercentCombined`, every 60 s and whenever the device list changes.
- The Bluetooth address comes from the Core Audio UID (the `BluetoothAddress` part before the suffix).
- Shown on the card's status line. Red at 15% or less. Hidden when the value is unknown.

### 16.2 Reconnect
- `SpeakerReconnector` calls `IOBluetoothDevice.openConnection` 5 s after an assigned Bluetooth speaker disappears, then every 30 s, and gives up after 10 minutes.
- Setting "Reconnect speakers that drop", default on.
- A disconnected card shows a Reconnect button that tries once immediately.

### 16.3 Keep-alive
- `domine_kernel_set_keep_alive(enabled)`. After 2 s of output below -80 dBFS, the kernel adds a 15 Hz sine at -60 dBFS. 15 Hz is below the Grip's 70 Hz range, so it is not audible, but it keeps the speaker from powering off.
- 50 ms fade in. 10 ms fade out when audio returns.
- Skipped during the test tone, click and chirp, and while muted.
- Bit-exact when off. Setting "Keep speakers from turning off", default on.

### 16.4 Hints
- Grip pairing hint: shown when only one "JBL Grip" is present (section 9).
- Phone takeover hints: in stereo the text is appended to the mono fallback banner. In surround the text names the missing side.
- Priority when several apply: mono fallback, phone takeover, pairing.

### 16.5 Crossfeed and same sound on both
- `domine_kernel_set_crossfeed(a)` with a from 0 to 1. Side A output is `A = (1 - a/2)L + (a/2)R`, and side B mirrors it.
- Changes ramp over 20 ms. Ignored in mono fallback.
- a = 1 gives the same sound on both speakers, labelled "Same sound on both speakers" in the UI.

### 16.6 Night mode
- A per-side effects flag. While on, it overrides the compressor (threshold about -30 dB, ratio 6:1, +6 dB makeup, limiter on) and adds the Loudness EQ curve.
- The user's own compressor and EQ settings are stored unchanged and restored when night mode is turned off.

### 16.7 Delay nudge
- Buttons -5, -1, +1 and +5 ms in Tuning. Arrow keys nudge by 1 ms, Shift with an arrow by 5 ms.
- Results are clamped to the current slider range (section 4).

### 16.8 Now Playing
- Removed in 0.2.2. MediaRemote returns no now playing information to third-party apps on current macOS, so the row never appeared. Only sending commands is still used (section 16.11).

### 16.9 Rooms export and import
- Export writes a `.domine-rooms` file, JSON of the form `{"version":1,"rooms":[...]}`.
- Import adds the rooms. A name that already exists gets " 2", then " 3", and so on.

### 16.10 Diagnostics
- Copy Report puts a fenced plain text report on the clipboard.
- Per-speaker dropout counts: sub-device processor overloads and disconnects. Reset Counts clears them.

### 16.11 Pause on exit
- Settings > General: "Pause playback if Domine quits while playing", on by default.
- While routing with the setting on, Domine runs one watchdog: its own executable relaunched with `--pause-watchdog <pid>`. The watchdog handles that argument before any UI starts, so it has no Dock icon or window.
- The watchdog waits for Domine to exit (kqueue `NOTE_EXIT`), sends MediaRemote pause (never toggle), and exits. If Domine is already gone, it pauses at once. This covers quitting and crashing, so playback does not move to the Mac's own speakers.
- When routing stops while Domine keeps running, or the setting is turned off, Domine sends the watchdog SIGTERM and it exits without pausing. On quit while routing, Domine leaves it running.
- The unit test host never launches a watchdog.

### 16.12 Bluetooth Speakers window
- Domine's own window for Bluetooth speakers, so the user never needs System Settings > Bluetooth. Opened from "Bluetooth…" in the Choose Speaker sheet and "Bluetooth Speakers…" in the menu bar menu.
- My Speakers: Domine's remembered list (address and last known name, saved in settings, kept across launches). A speaker joins it when it is connected or paired from this window, or assigned to a side or the surround set. Forget removes it from Domine's list only; macOS stays paired.
- Other Paired Speakers: paired audio devices not in My Speakers, in a collapsed group.
- Nearby: Search runs an IOBluetooth inquiry for about 10 s and lists unpaired audio devices. Pair pairs, then connects.
- Only audio-class devices are shown. Nothing is ever opened for input.
