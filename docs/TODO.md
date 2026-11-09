# To do

- Fix `RoutingSettingsTests.surroundWaitsForEverySpeakerOfTheSet`. It fails on main (found 2026-11-08): `model.autoStartTask` is already set after Grip B reconnects, while speaker C is still disconnected. Surround auto-start should wait for every speaker in the set (`RoutingSettingsTests.swift:78`).
- Three volume-link tests fail on main (found 2026-11-08), probably since `0eac77c` ("Volume link: hard limits so volume can never jump up"). A raise on one speaker is no longer copied to the other: `HardwareVolumeTests.changeOnOneSpeakerIsCopiedToTheOther`, `HardwareVolumeTests.suppressionWindowIgnoresChangesRightAfterDomineWrote`, `VirtualOutputTests.gripButtonWritesBackToTheVirtualDeviceOnce`. Decide whether the tests or the limit are wrong.
- `KeepAliveTests.silenceGetsSignalAfterTwoSeconds` and `SurroundKeepAliveTests.silenceGetsSignalAfterTwoSeconds` fail on main (found 2026-11-08): the keep-alive tone shows up before 2 s of silence have passed.
