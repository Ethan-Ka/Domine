# To do

- Fix `RoutingSettingsTests.surroundWaitsForEverySpeakerOfTheSet`. It fails on main (found 2026-11-08): `model.autoStartTask` is already set after Grip B reconnects, while speaker C is still disconnected. Surround auto-start should wait for every speaker in the set (`RoutingSettingsTests.swift:78`).
