import Foundation
import Testing
@testable import Domine

@MainActor
final class SettingsTests {
    let suiteName = UUID().uuidString
    let defaults: UserDefaults
    let store: SettingsStore

    static let gripA = "60-FD-A6-19-4F-2A:output"
    static let gripB = "60-FD-A6-19-9C-11:output"

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        store = SettingsStore(defaults: defaults)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    // MARK: Pair key

    @Test func pairKeyIsSortedAndFlagsSwap() {
        let forward = PairKey(leftUID: Self.gripA, rightUID: Self.gripB)
        let reverse = PairKey(leftUID: Self.gripB, rightUID: Self.gripA)
        #expect(forward.rawValue == "60-FD-A6-19-4F-2A:output|60-FD-A6-19-9C-11:output")
        #expect(reverse.rawValue == forward.rawValue)
        #expect(!forward.isSwapped)
        #expect(reverse.isSwapped)
        #expect(SettingsStore.storageKey(for: forward)
            == "Domine.pair.60-FD-A6-19-4F-2A:output|60-FD-A6-19-9C-11:output")
    }

    // MARK: Pair settings

    @Test func unknownPairReturnsDefaults() {
        let s = store.pairSettings(leftUID: Self.gripA, rightUID: Self.gripB)
        #expect(s == PairSettings(delayMs: 0, extendedRange: false, balance: 0, masterVolume: 0.5))
        #expect(s.leftGain == 1)
        #expect(s.rightGain == 1)
    }

    @Test func pairSettingsRoundTrip() {
        let s = PairSettings(delayMs: 12, extendedRange: true, balance: -0.25, masterVolume: 0.75)
        store.setPairSettings(s, leftUID: Self.gripA, rightUID: Self.gripB)
        #expect(store.pairSettings(leftUID: Self.gripA, rightUID: Self.gripB) == s)
        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.pairSettings(leftUID: Self.gripA, rightUID: Self.gripB) == s)
    }

    @Test func swappedOrderFindsSamePairFlipped() {
        store.setPairSettings(
            PairSettings(delayMs: 12, extendedRange: true, balance: -0.25, masterVolume: 0.75),
            leftUID: Self.gripA, rightUID: Self.gripB)
        let swapped = store.pairSettings(leftUID: Self.gripB, rightUID: Self.gripA)
        #expect(swapped == PairSettings(delayMs: -12, extendedRange: true, balance: 0.25, masterVolume: 0.75))
        #expect(swapped.leftGain == 0.75)
        #expect(swapped.rightGain == 1)
    }

    @Test func savingInSwappedOrderUpdatesSameRecord() {
        store.setPairSettings(PairSettings(delayMs: 5), leftUID: Self.gripA, rightUID: Self.gripB)
        store.setPairSettings(
            PairSettings(delayMs: 40, balance: 0.5), leftUID: Self.gripB, rightUID: Self.gripA)
        #expect(store.pairSettings(leftUID: Self.gripA, rightUID: Self.gripB)
            == PairSettings(delayMs: -40, balance: -0.5))
        let pairKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("Domine.pair.") }
        #expect(pairKeys.count == 1)
    }

    @Test func removePairSettingsRestoresDefaults() {
        store.setPairSettings(PairSettings(delayMs: 5), leftUID: Self.gripA, rightUID: Self.gripB)
        store.removePairSettings(leftUID: Self.gripB, rightUID: Self.gripA)
        #expect(store.pairSettings(leftUID: Self.gripA, rightUID: Self.gripB) == PairSettings())
    }

    @Test func corruptPairJSONFallsBackToDefaults() {
        let key = SettingsStore.storageKey(for: PairKey(leftUID: Self.gripA, rightUID: Self.gripB))
        defaults.set(Data("not json".utf8), forKey: key)
        #expect(store.pairSettings(leftUID: Self.gripA, rightUID: Self.gripB) == PairSettings())
        defaults.set("a string, not data", forKey: key)
        #expect(store.pairSettings(leftUID: Self.gripA, rightUID: Self.gripB) == PairSettings())
    }

    @Test func partialAndMistypedFieldsDefaultIndividually() {
        let key = SettingsStore.storageKey(for: PairKey(leftUID: Self.gripA, rightUID: Self.gripB))
        let json = #"{"delayMs": 7, "balance": "left", "futureField": 1}"#
        defaults.set(Data(json.utf8), forKey: key)
        #expect(store.pairSettings(leftUID: Self.gripA, rightUID: Self.gripB)
            == PairSettings(delayMs: 7, extendedRange: false, balance: 0, masterVolume: 0.5))
    }

    @Test func outOfRangeStoredValuesAreClamped() {
        let key = SettingsStore.storageKey(for: PairKey(leftUID: Self.gripA, rightUID: Self.gripB))
        let json = #"{"delayMs": -900, "balance": 3, "masterVolume": 1.5}"#
        defaults.set(Data(json.utf8), forKey: key)
        #expect(store.pairSettings(leftUID: Self.gripA, rightUID: Self.gripB)
            == PairSettings(delayMs: -300, extendedRange: false, balance: 1, masterVolume: 1))
    }

    @Test func nonFiniteValuesFallBackToDefaults() {
        let s = PairSettings(delayMs: .nan, balance: .infinity, masterVolume: .nan)
        #expect(s == PairSettings())
    }

    // MARK: Balance mapping

    @Test func balanceAttenuatesOnlyTheOtherSide() {
        let centered = PairSettings(balance: 0)
        #expect([centered.leftGain, centered.rightGain] == [1, 1])
        let right = PairSettings(balance: 0.25)
        #expect([right.leftGain, right.rightGain] == [0.75, 1])
        let left = PairSettings(balance: -0.5)
        #expect([left.leftGain, left.rightGain] == [1, 0.5])
        let fullRight = PairSettings(balance: 1)
        #expect([fullRight.leftGain, fullRight.rightGain] == [0, 1])
        let fullLeft = PairSettings(balance: -1)
        #expect([fullLeft.leftGain, fullLeft.rightGain] == [1, 0])
    }

    @Test func swappedIsItsOwnInverseAndKeepsZeroPositive() {
        let s = PairSettings(delayMs: 0, extendedRange: true, balance: 0, masterVolume: 0.25)
        #expect(s.swapped == s)
        #expect(s.swapped.delayMs.sign == .plus)
        let t = PairSettings(delayMs: -3, balance: 0.5)
        #expect(t.swapped.swapped == t)
    }

    // MARK: Globals

    @Test func globalDefaults() {
        #expect(store.lastLeftUID == nil)
        #expect(store.lastRightUID == nil)
        #expect(store.volumeKeysEnabled == false)
        #expect(store.restorePreviousOutput == true)
        #expect(store.closeBehavior == .keepPlaying)
        #expect(store.startWhenBothConnect == true)
        #expect(store.previousOutputUID == nil)
        #expect(store.excludedAppsPlayThroughUID == nil)
        #expect(store.exclusions == [])
    }

    @Test func globalsRoundTripAcrossStores() {
        store.lastLeftUID = Self.gripA
        store.lastRightUID = Self.gripB
        store.volumeKeysEnabled = true
        store.restorePreviousOutput = false
        store.closeBehavior = .stopPlaying
        store.startWhenBothConnect = true
        store.previousOutputUID = "BuiltInSpeakerDevice"
        store.excludedAppsPlayThroughUID = "AirPods:output"
        store.exclusions = [
            AppExclusion(bundleID: "us.zoom.xos", mode: .onlyDuringCalls),
            AppExclusion(bundleID: "com.apple.FaceTime", mode: .always),
        ]

        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.lastLeftUID == Self.gripA)
        #expect(reopened.lastRightUID == Self.gripB)
        #expect(reopened.volumeKeysEnabled == true)
        #expect(reopened.restorePreviousOutput == false)
        #expect(reopened.closeBehavior == .stopPlaying)
        #expect(reopened.startWhenBothConnect == true)
        #expect(reopened.previousOutputUID == "BuiltInSpeakerDevice")
        #expect(reopened.excludedAppsPlayThroughUID == "AirPods:output")
        #expect(reopened.exclusions == [
            AppExclusion(bundleID: "us.zoom.xos", mode: .onlyDuringCalls),
            AppExclusion(bundleID: "com.apple.FaceTime", mode: .always),
        ])
    }

    @Test func settingOptionalToNilRemovesIt() {
        store.previousOutputUID = "BuiltInSpeakerDevice"
        store.previousOutputUID = nil
        #expect(store.previousOutputUID == nil)
        #expect(defaults.object(forKey: "Domine.previousOutputUID") == nil)
    }

    @Test func globalsUseKeyPrefix() {
        store.volumeKeysEnabled = true
        store.closeBehavior = .stopPlaying
        #expect(defaults.object(forKey: "Domine.volumeKeysEnabled") as? Bool == true)
        #expect(defaults.string(forKey: "Domine.closeBehavior") == "stopPlaying")
    }

    @Test func wrongTypedGlobalsFallBackToDefaults() {
        defaults.set("yes", forKey: "Domine.restorePreviousOutput")
        defaults.set("minimize", forKey: "Domine.closeBehavior")
        defaults.set(42, forKey: "Domine.lastLeftUID")
        #expect(store.restorePreviousOutput == true)
        #expect(store.closeBehavior == .keepPlaying)
        #expect(store.lastLeftUID == nil)
    }

    @Test func corruptExclusionsFallBackToEmpty() {
        defaults.set(Data("{broken".utf8), forKey: "Domine.exclusions")
        #expect(store.exclusions == [])
    }

    @Test func badExclusionEntriesAreDropped() {
        let json = #"""
        [{"bundleID": "com.hnc.Discord", "mode": "always"},
         {"bundleID": "com.microsoft.teams2", "mode": "sometimes"},
         {"mode": "always"},
         {"bundleID": "us.zoom.xos", "mode": "onlyDuringCalls"}]
        """#
        defaults.set(Data(json.utf8), forKey: "Domine.exclusions")
        #expect(store.exclusions == [
            AppExclusion(bundleID: "com.hnc.Discord", mode: .always),
            AppExclusion(bundleID: "us.zoom.xos", mode: .onlyDuringCalls),
        ])
    }
}
