import SwiftUI
import Testing
@testable import Domine

@MainActor
struct UIStateTests {
    @Test func delayReadoutFollowsSignConvention() {
        #expect(TuningState.delayReadout(4) == "Right +4 ms")
        #expect(TuningState.delayReadout(-3) == "Left +3 ms")
        #expect(TuningState.delayReadout(0) == "In sync")
    }

    @Test func balanceReadout() {
        #expect(TuningState.balanceReadout(0) == "Centered")
        #expect(TuningState.balanceReadout(0.25) == "Right 25%")
        #expect(TuningState.balanceReadout(-0.1) == "Left 10%")
    }

    @Test func delayRangeWidensWithExtendedRange() {
        var state = SampleStates.tuning
        #expect(state.delayRange == -50...50)
        state.isExtendedRange = true
        #expect(state.delayRange == -300...300)
    }

    @Test func meterSegmentColors() {
        let colors = (0..<LevelMeter.segmentCount).map(LevelMeter.litColor(at:))
        #expect(colors[0..<11].allSatisfy { $0 == .green })
        #expect(colors[11..<14].allSatisfy { $0 == .yellow })
        #expect(colors[14..<16].allSatisfy { $0 == .red })
    }

    @Test func meterLitCount() {
        #expect(LevelMeter.litCount(for: 0) == 0)
        #expect(LevelMeter.litCount(for: 0.62) == 10)
        #expect(LevelMeter.litCount(for: 1) == 16)
        #expect(LevelMeter.litCount(for: 2) == 16)
        #expect(LevelMeter.litCount(for: -1) == 0)
    }

    @Test func missingPositionsArePlaceholders() {
        let card = SampleStates.off.speaker(at: .rearLeft)
        #expect(card.connection == .placeholder)
        #expect(card.statusText == "Planned for quad mode")
    }

    @Test func cardsHaveNoSecondLineByDefault() {
        #expect(SampleStates.frontLeft.statusDetail == nil)
        #expect(SampleStates.monoFallback.speaker(at: .frontRight).statusDetail == nil)
    }

    @Test func assignSelection() {
        #expect(SampleStates.assign.selectedUID == "60-FD-A6-19-4F-2A:output")
        #expect(SampleStates.assign.title == "Choose the Front Left speaker")
    }

    @Test func stageConnectorsMeetInnerCardEdges() {
        let layout = StageLayout(size: StageLayout.designSize, mode: .quad)
        #expect(layout.macCenter == CGPoint(x: 308, y: 150))
        #expect(layout.connectorEnd(.frontLeft) == CGPoint(x: 196, y: 66))
        #expect(layout.connectorEnd(.frontRight) == CGPoint(x: 420, y: 66))
        #expect(layout.connectorEnd(.rearLeft) == CGPoint(x: 196, y: 254))
        #expect(layout.connectorEnd(.rearRight) == CGPoint(x: 420, y: 254))
    }

    /// The banner stays between the rear cards so their text is not covered.
    @Test(arguments: [StageLayout.designSize, CGSize(width: 900, height: 640), CGSize(width: 1400, height: 700)])
    func bannerClearsTheRearCards(size: CGSize) {
        let layout = StageLayout(size: size, mode: .quad)
        let bannerMinX = (size.width - layout.bannerWidth) / 2
        let bannerMaxX = bannerMinX + layout.bannerWidth
        let rearLeftMaxX = layout.cardCenter(.rearLeft).x + StageLayout.cardSize.width / 2
        let rearRightMinX = layout.cardCenter(.rearRight).x - StageLayout.cardSize.width / 2
        #expect(layout.bannerWidth > 150)
        #expect(layout.bannerWidth <= StageLayout.bannerMaxWidth)
        #expect(bannerMinX >= rearLeftMaxX + StageLayout.bannerGap)
        #expect(bannerMaxX <= rearRightMinX - StageLayout.bannerGap)
    }

    @Test func bannerIsLevelWithTheRearCards() {
        let layout = StageLayout(size: StageLayout.designSize, mode: .quad)
        let rearBottom = layout.cardCenter(.rearLeft).y + StageLayout.cardSize.height / 2
        #expect(layout.size.height - layout.bannerBottomInset == rearBottom)
    }

    @Test func stereoStageHasOnlyFrontCards() {
        #expect(SpeakerPosition.positions(in: .stereo) == [.frontLeft, .frontRight])
        #expect(SpeakerPosition.positions(in: .quad).count == 4)
    }

    @Test func stereoStageCentersTheFrontCards() {
        let layout = StageLayout(size: StageLayout.designSize)
        #expect(layout.macCenter == CGPoint(x: 308, y: 160))
        #expect(layout.cardCenter(.frontLeft).y == 160)
        #expect(layout.cardCenter(.frontRight).y == 160)
        #expect(layout.connectorEnd(.frontLeft) == CGPoint(x: 196, y: 160))
        #expect(layout.connectorEnd(.frontRight) == CGPoint(x: 420, y: 160))
    }
}
