import CoreGraphics
import Testing
@testable import Domine

/// On resize the cards, the guide circle and the sound field share one
/// center and one scale, so the cards stay put relative to the drawing.
@MainActor
struct StageLayoutResizeTests {
    static let small = StageLayout.designSize
    static let large = CGSize(width: 924, height: 480)

    private func offset(_ p: CGPoint, _ layout: StageLayout) -> CGPoint {
        CGPoint(x: p.x - layout.macCenter.x, y: p.y - layout.macCenter.y)
    }

    @Test func stereoCardsScaleWithGuideCircle() {
        let a = StageLayout(size: Self.small, mode: .stereo)
        let b = StageLayout(size: Self.large, mode: .stereo)
        let ratio = b.guideRadius / a.guideRadius
        #expect(abs(ratio - 1.5) < 0.0001)
        for position in SpeakerPosition.positions(in: .stereo) {
            let oa = offset(a.cardCenter(position), a)
            let ob = offset(b.cardCenter(position), b)
            #expect(abs(ob.x - oa.x * ratio) < 0.0001)
            #expect(abs(ob.y - oa.y * ratio) < 0.0001)
        }
    }

    @Test func stereoDefaultSizeIsUnchanged() {
        let layout = StageLayout(size: StageLayout.designSize, mode: .stereo)
        #expect(layout.cardCenter(.frontLeft) == CGPoint(x: 108, y: 160))
        #expect(layout.cardCenter(.frontRight) == CGPoint(x: 508, y: 160))
        #expect(layout.guideRadius == 118)
    }

    @Test func surroundCardsScaleWithGuideCircle() {
        let a = StageLayout(size: Self.small, mode: .surround)
        let b = StageLayout(size: Self.large, mode: .surround)
        let ratio = b.guideRadius / a.guideRadius
        #expect(abs(ratio - 1.5) < 0.0001)
        // Placements whose cards are not clamped at either size.
        let placements: [(Double, Double)] = [(90, 1), (-90, 1.5), (60, 1), (-120, 1.2)]
        for (azimuth, distance) in placements {
            let oa = offset(a.surroundCardCenter(azimuth: azimuth, distance: distance), a)
            let ob = offset(b.surroundCardCenter(azimuth: azimuth, distance: distance), b)
            #expect(abs(ob.x - oa.x * ratio) < 0.0001)
            #expect(abs(ob.y - oa.y * ratio) < 0.0001)
            // The sound field's dots sit on the guide circle around the same center.
            let dot = offset(b.point(azimuth: azimuth, radius: b.guideRadius), b)
            #expect(abs((dot.x * dot.x + dot.y * dot.y).squareRoot() - b.guideRadius) < 0.0001)
        }
    }

    @Test(arguments: [CGSize(width: 536, height: 260), CGSize(width: 1400, height: 400), CGSize(width: 616, height: 700)])
    func cardsStayInsideStage(size: CGSize) {
        let half = CGSize(width: StageLayout.cardSize.width / 2, height: StageLayout.cardSize.height / 2)
        let stereo = StageLayout(size: size, mode: .stereo)
        var centers = SpeakerPosition.positions(in: .stereo).map { stereo.cardCenter($0) }
        let surround = StageLayout(size: size, mode: .surround)
        for azimuth in stride(from: -180.0, through: 180, by: 45) {
            for distance in [0.5, 2, 10] {
                centers.append(surround.surroundCardCenter(azimuth: azimuth, distance: distance))
            }
        }
        for c in centers {
            #expect(c.x - half.width >= 0)
            #expect(c.x + half.width <= size.width)
            #expect(c.y - half.height >= 0)
            #expect(c.y + half.height <= size.height)
        }
    }
}
