# Domine

Small macOS windowed app (not a menu bar app) that plays system audio left channel on one output device and right channel on another (typically two Bluetooth speakers). Full design is in `docs/SPEC.md`. UI uses default macOS controls only. Screen layouts are in `docs/mockups/` (start with its README); follow them for structure, labels, and placement. Read it before starting any milestone, and follow the milestone order in section 10.

## Setup assumptions
- Xcode 16 or newer and XcodeGen (`brew install xcodegen`) are installed. If either is missing, stop and tell the user.
- The user has two JBL Grip speakers, unpaired from each other in the JBL Portable app, both connected to this Mac.

## Commands
- Generate project: `xcodegen generate`
- Build: `xcodebuild -scheme Domine -configuration Debug -destination 'platform=macOS' build`
- Test: `xcodebuild -scheme Domine -destination 'platform=macOS' test`
- Run all three after any change to `project.yml` or new source files.

## Hard rules
- Never edit `Domine.xcodeproj` by hand. Change `project.yml` and regenerate.
- Deployment target is macOS 14.4. Do not add availability checks for older versions.
- Code in `Sources/DomineDSP/` runs on the real-time audio thread: no malloc/free, no locks, no Objective-C or Swift calls, no logging, no I/O. Parameters cross threads through C11 atomics only.
- Swift code never runs inside the IOProc except the minimal trampoline that calls `domine_kernel_process`.
- All Core Audio property access goes through the `AudioHAL` protocol in `Audio/CoreAudioHAL.swift`. Other files do not call `AudioObjectGetPropertyData` directly.
- Check every `OSStatus`. Convert non-zero results into a Swift error that includes the four-char code and the property selector.
- Identify devices by UID (`kAudioDevicePropertyDeviceUID`), never by `AudioObjectID`; IDs change across reconnects.
- The aggregate device is always private and always rebuilt from scratch. Never mutate a running aggregate.
- Never open a Bluetooth device for input.
- Reference hardware is two JBL Grip speakers (mono, one driver each; see SPEC section 1a). Each speaker must receive its side on both of its channels. Both report the name "JBL Grip", so never use the device name as a key or as the only label in the UI.
- Volume is Domine's job, not the system's: the tap captures pre-volume audio. Keep the two speakers' hardware volumes linked (SPEC section 4a).

## Style
- Swift 6 strict concurrency. UI state lives in an `@Observable` `AppModel` on the main actor.
- Small files, one type per file where practical.
- Tests: every kernel feature gets a unit test with a known input buffer and exact expected output. Engine logic is tested against the fake HAL.

## Verifying audio work
Automated tests cannot confirm what the speakers actually play. After finishing M0, M3, or M4, stop and ask the user to do a manual listening test, and describe exactly what they should hear.

## Working style
- One milestone at a time, in SPEC order. At the end of each milestone: build, run tests, summarize what changed, list anything untested, and wait for the user before starting the next.
- Commit at the end of each milestone with a message like `M1: device catalog and fake HAL`.
- When the spec is unclear or wrong about a Core Audio behavior you observe, say so and propose a spec edit rather than silently working around it.
