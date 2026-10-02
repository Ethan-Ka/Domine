import CoreGraphics
import Testing
@testable import Domine

/// Surround stage geometry, card labels, and the demo's view state.
@MainActor
struct SurroundUITests {
    let layout = StageLayout(size: StageLayout.designSize, mode: .surround)

    @Test func listenerSitsInTheMiddle() {
        #expect(layout.macCenter == CGPoint(x: 308, y: 160))
    }

    @Test func distanceMapsOntoTheStageRadius() {
        #expect(layout.surroundRadius(forDistance: 0.5) == StageLayout.surroundMinRadius)
        #expect(layout.surroundRadius(forDistance: 10) == layout.surroundMaxRadius)
        #expect(layout.surroundMaxRadius == 296)
        // Out-of-range distances clamp.
        #expect(layout.surroundRadius(forDistance: 0.1) == StageLayout.surroundMinRadius)
        #expect(layout.surroundRadius(forDistance: 50) == layout.surroundMaxRadius)
        #expect(layout.surroundRadius(forDistance: 1) < layout.surroundRadius(forDistance: 2))
    }

    @Test(arguments: [-150.0, -90, -30, 0, 45, 110, 170])
    func placementRoundTrips(azimuth: Double) {
        for distance in [0.5, 1.5, 3, 10] {
            let point = layout.surroundPoint(azimuth: azimuth, distance: distance)
            let placement = layout.surroundPlacement(at: point)
            #expect(abs(placement.azimuth - azimuth) < 0.001)
            #expect(abs(placement.distance - distance) < 0.001)
        }
    }

    @Test func zeroDegreesIsStraightUp() {
        let point = layout.surroundPoint(azimuth: 0, distance: 2)
        #expect(abs(point.x - layout.macCenter.x) < 0.001)
        #expect(point.y < layout.macCenter.y)
        let right = layout.surroundPoint(azimuth: 90, distance: 2)
        #expect(right.x > layout.macCenter.x)
        #expect(abs(right.y - layout.macCenter.y) < 0.001)
    }

    @Test func cardsStayInsideTheStage() {
        let half = CGSize(width: StageLayout.cardSize.width / 2, height: StageLayout.cardSize.height / 2)
        for azimuth in stride(from: -180.0, through: 180, by: 15) {
            for distance in [0.5, 2, 10] {
                let c = layout.surroundCardCenter(azimuth: azimuth, distance: distance)
                #expect(c.x - half.width >= StageLayout.cardInset.width)
                #expect(c.x + half.width <= layout.size.width - StageLayout.cardInset.width)
                #expect(c.y - half.height >= StageLayout.cardInset.height)
                #expect(c.y + half.height <= layout.size.height - StageLayout.cardInset.height)
            }
        }
    }

    @Test func connectorMeetsTheCardEdgeFacingTheListener() {
        let center = CGPoint(x: 120, y: 66)
        let end = layout.surroundConnectorEnd(cardCenter: center)
        let onVerticalEdge = abs(abs(end.x - center.x) - StageLayout.cardSize.width / 2) < 0.001
        let onHorizontalEdge = abs(abs(end.y - center.y) - StageLayout.cardSize.height / 2) < 0.001
        #expect(onVerticalEdge || onHorizontalEdge)
        // On the Mac's side of the card.
        #expect(end.x > center.x)
        #expect(end.y > center.y)
        // A card over the Mac has no visible connector.
        #expect(layout.surroundConnectorEnd(cardCenter: layout.macCenter) == layout.macCenter)
    }

    @Test func guideCircleFitsTheStage() {
        #expect(layout.guideRadius > StageLayout.surroundMinRadius)
        #expect(layout.guideRadius <= layout.size.height / 2 - StageLayout.guideMargin)
        let marker = layout.demoMarker(azimuth: -90)
        #expect(abs(marker.x - (layout.macCenter.x - layout.guideRadius)) < 0.001)
    }

    @Test func dragsSnapToFiveDegrees() {
        #expect(SurroundCardInfo.snapped(-32.4) == -30)
        #expect(SurroundCardInfo.snapped(47.6) == 50)
        #expect(SurroundCardInfo.snapped(178) == 180)
        #expect(SurroundCardInfo.snapped(-178) == 180)
    }

    @Test func sideTagShowsTheAngle() {
        #expect(SurroundCardInfo.angleTag(-30) == "-30°")
        #expect(SurroundCardInfo.angleTag(110) == "110°")
        #expect(SurroundCardInfo.angleTag(-0.4) == "0°")
        #expect(SampleStates.surround.surroundCards.map(\.sideTag) == ["-30°", "30°", "0°", "-110°", "110°"])
    }

    @Test func cardTitlesFollowTheDirection() {
        #expect(SurroundCardInfo.title(forAzimuth: 0) == "Center")
        #expect(SurroundCardInfo.title(forAzimuth: -30) == "Front Left")
        #expect(SurroundCardInfo.title(forAzimuth: 90) == "Side Right")
        #expect(SurroundCardInfo.title(forAzimuth: -110) == "Rear Left")
        #expect(SurroundCardInfo.title(forAzimuth: 180) == "Rear Center")
    }

    @Test func surroundCardsAreKeyedByUID() {
        let cards = SampleStates.surround.surroundCards
        #expect(cards.count == 5)
        #expect(Set(cards.map(\.id)).count == 5)
        #expect(cards[0].title == "Front Left")
        // Stereo lookups never return a Surround card.
        #expect(SampleStates.surround.speaker(at: .frontLeft).connection == .placeholder)
    }

    @Test func orbitReadsOffAtZero() {
        #expect(SurroundControls.orbitText(0) == "Off")
        #expect(SurroundControls.orbitText(0.25) == "0.25/s")
        #expect(SurroundControls.orbitText(2) == "2.00/s")
        let controls = SurroundControls(width: 30, level: 0.8, orbitRate: 0, rotation: -45)
        #expect(controls.widthText == "30°")
        #expect(controls.levelText == "80%")
        #expect(controls.rotationText == "-45°")
    }

    @Test func demoStatusAndButton() {
        #expect(DemoState().statusLine == nil)
        #expect(DemoState().buttonTitle == "Play Demo")
        let playing = DemoState(isPlaying: true, azimuth: 30, sectionTitle: "Orbit")
        #expect(playing.statusLine == "Demo: Orbit")
        #expect(playing.buttonTitle == "Stop Demo")
        #expect(SampleStates.tuningDemo.demoButtonTitle == "Stop Demo")
        #expect(SampleStates.tuningDemo.demoCaption == "Now playing: Ping-pong")
        #expect(SampleStates.tuning.demoCaption == nil)
    }

    @Test func routingModeReadsTheOldQuadValue() {
        #expect(RoutingMode(rawValue: "quad") == .surround)
        #expect(RoutingMode(rawValue: "surround") == .surround)
        #expect(RoutingMode.surround.rawValue == "surround")
        #expect(RoutingMode.surround.title == "Surround")
    }

    @Test func surroundAssignSheetTitles() {
        #expect(SampleStates.assignSurroundAdd.title == "Add a speaker")
        #expect(SampleStates.assignSurroundAdd.confirmTitle == "Add Speaker")
        #expect(SampleStates.assign.confirmTitle == "Use This Speaker")
        #expect(SurroundAssignTarget.replace(uid: "x").replacedUID == "x")
        #expect(SurroundAssignTarget.add.replacedUID == nil)
    }

    @Test func demoButtonsFollowCanPlay() {
        #expect(!DemoState(isPlaying: false, canPlay: false).isButtonEnabled)
        #expect(DemoState(isPlaying: true, canPlay: false).isButtonEnabled)
        var tuning = SampleStates.tuning
        tuning.canPlayDemo = false
        #expect(!tuning.isDemoButtonEnabled)
        tuning.isDemoPlaying = true
        #expect(tuning.isDemoButtonEnabled)
    }

    @Test func surroundTuningReadouts() throws {
        let rows = try #require(SampleStates.tuningSurround.surroundRows)
        #expect(rows.count == 5)
        #expect(rows[0].offsetReadout == "No delay")
        #expect(rows[1].offsetReadout == "+12 ms")
        #expect(rows[1].trimReadout == "90%")
        #expect(rows[1].label == "Front Right 9C11")
        #expect(SampleStates.tuning.surroundRows == nil)
    }

    @Test func surroundSoundEditsThePickedSpeaker() throws {
        let sound = try #require(SampleStates.soundSurround.surround)
        #expect(sound.editedUID(selection: nil) == sound.speakers[0].uid)
        #expect(sound.editedUID(selection: sound.speakers[1].uid) == sound.speakers[1].uid)
        #expect(sound.editedUID(selection: "gone") == sound.speakers[0].uid)
        var linked = sound
        linked.isLinked = true
        #expect(linked.editedUID(selection: sound.speakers[1].uid) == sound.speakers[0].uid)
        #expect(sound.effects(for: sound.speakers[1].uid) == PairSettings.Preset.bassBoost.settings.left)
    }

    @Test func presetsNeedTheRightSpeakerCount() {
        let count = SampleStates.surround.surroundCards.count
        #expect(SurroundPreset.five.isEnabled(speakerCount: count))
        #expect(!SurroundPreset.quad.isEnabled(speakerCount: count))
        #expect(SurroundPreset.ring.isEnabled(speakerCount: count))
    }
}
