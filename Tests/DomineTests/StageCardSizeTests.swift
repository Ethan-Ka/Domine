import CoreGraphics
import Foundation
import Testing
@testable import Domine

@MainActor
struct StageCardSizeTests {
    private static let sizes = [CGSize(width: 520, height: 240), CGSize(width: 616, height: 320), CGSize(width: 924, height: 480)]

    private func frames(_ layout: StageLayout, azimuths: [Double], distance: Double) -> [CGRect] {
        let card = layout.cardSize
        return azimuths.map {
            let c = layout.surroundCardCenter(azimuth: $0, distance: distance)
            return CGRect(x: c.x - card.width / 2, y: c.y - card.height / 2, width: card.width, height: card.height)
        }
    }

    @Test func compactForCrowdedOrSmallStages() {
        #expect(StageLayout(size: Self.sizes[2], mode: .surround, speakerCount: 4).isCompact == false)
        #expect(StageLayout(size: Self.sizes[2], mode: .surround, speakerCount: 5).isCompact)
        #expect(StageLayout(size: Self.sizes[0], mode: .surround, speakerCount: 2).isCompact)
        #expect(StageLayout(size: Self.sizes[0], mode: .single, speakerCount: 1).cardSize == StageLayout.cardSize)
    }

    @Test func eightRingCardsDoNotOverlapAndStayInside() {
        let azimuths = (0..<8).map { -180 + 360 * (Double($0) + 0.5) / 8 }
        for size in Self.sizes {
            let layout = StageLayout(size: size, mode: .surround, speakerCount: 8)
            let rects = frames(layout, azimuths: azimuths, distance: 2)
            for (i, a) in rects.enumerated() {
                #expect(CGRect(origin: .zero, size: size).contains(a))
                for b in rects[(i + 1)...] { #expect(!a.intersects(b)) }
            }
        }
    }

    @Test func stereoCardsDoNotOverlap() {
        for size in Self.sizes {
            let layout = StageLayout(size: size, mode: .stereo)
            let l = layout.cardCenter(.frontLeft), r = layout.cardCenter(.frontRight)
            #expect(r.x - l.x >= layout.cardSize.width)
        }
    }

    @Test func parsesBatteryValues() {
        #expect(IOBluetoothBatteryReader.parsePercent(NSNumber(value: 42)) == 42)
        #expect(IOBluetoothBatteryReader.parsePercent(NSNumber(value: 0)) == nil)
        #expect(IOBluetoothBatteryReader.parsePercent("x") == nil)
        #expect(IOBluetoothBatteryReader.parseCharging(NSNumber(value: true)) == true)
        #expect(IOBluetoothBatteryReader.parseCharging(nil) == nil)
    }
}
