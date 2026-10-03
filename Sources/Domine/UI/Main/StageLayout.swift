import CoreGraphics
import Foundation

/// Geometry of the stage, taken from docs/mockups/Main.dc.html (616 x 320
/// design size) and stretched to the real size.
struct StageLayout: Equatable, Sendable {
    let size: CGSize
    /// Stereo draws two front cards in the middle row; Surround is a top-down
    /// room with the listener in the middle.
    var mode: RoutingMode = .stereo

    static let designSize = CGSize(width: 616, height: 320)
    static let cardInset = CGSize(width: 20, height: 16)

    static let cardSize = CGSize(width: 176, height: 100)
    private var cardSize: CGSize { Self.cardSize }

    /// Center of the Mac symbol, which is where the listener sits.
    var macCenter: CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    var guideRadius: CGFloat {
        switch mode {
        case .stereo:
            return 118 * min(size.width / Self.designSize.width, size.height / Self.designSize.height)
        case .surround:
            // The 2 m ring, kept inside the stage.
            let fit = min(size.width, size.height) / 2 - Self.guideMargin
            return max(0, min(surroundRadius(forDistance: 2), fit))
        }
    }

    /// Space between the Surround guide circle and the stage edge.
    static let guideMargin: CGFloat = 12

    func cardCenter(_ position: SpeakerPosition) -> CGPoint {
        let halfW = cardSize.width / 2
        let x = position.isLeft
            ? Self.cardInset.width + halfW
            : size.width - Self.cardInset.width - halfW
        return CGPoint(x: x, y: size.height / 2)
    }

    /// Where the connector leaves the Mac: just outside the symbol, on the
    /// line from the Mac's center to the card.
    func connectorStart(_ position: SpeakerPosition) -> CGPoint {
        connectorStart(toward: connectorEnd(position))
    }

    /// Just outside the Mac symbol, on the line from its center to `end`.
    func connectorStart(toward end: CGPoint) -> CGPoint {
        let dx = end.x - macCenter.x
        let dy = end.y - macCenter.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > Self.macClearance else { return macCenter }
        let scale = Self.macClearance / length
        return CGPoint(x: macCenter.x + dx * scale, y: macCenter.y + dy * scale)
    }

    /// Space kept between the banner and the cards beside it.
    static let bannerGap: CGFloat = 10
    /// Widest the banner gets on a large stage (the mockup's width).
    static let bannerMaxWidth: CGFloat = 316

    /// The banner spans the stage bottom, up to the mockup's width.
    var bannerWidth: CGFloat {
        max(0, min(Self.bannerMaxWidth, size.width - 2 * Self.cardInset.width))
    }

    /// Distance from the stage's bottom edge to the banner's bottom edge.
    var bannerBottomInset: CGFloat { Self.cardInset.height }

    /// Radius around the Mac's center that connectors leave clear.
    static let macClearance: CGFloat = 50

    /// Where the connector meets the card: middle of the edge facing the Mac.
    func connectorEnd(_ position: SpeakerPosition) -> CGPoint {
        let center = cardCenter(position)
        let dx = cardSize.width / 2
        return CGPoint(x: position.isLeft ? center.x + dx : center.x - dx, y: center.y)
    }

    // MARK: - Surround

    /// Radius of the nearest distance (0.5 m): clear of the Mac symbol.
    static let surroundMinRadius: CGFloat = 70

    /// Radius of the farthest distance (10 m). Uses the longer side so the
    /// whole range stays draggable; cards are clamped inside the stage.
    var surroundMaxRadius: CGFloat {
        max(Self.surroundMinRadius + 1, max(size.width, size.height) / 2 - Self.guideMargin)
    }

    private static let minDistance = Double(SurroundSpeaker.distanceRange.lowerBound)
    private static let maxDistance = Double(SurroundSpeaker.distanceRange.upperBound)

    /// Distance in metres to radius in points. Logarithmic, so the usual
    /// 1 to 4 m spread out instead of crowding the Mac.
    func surroundRadius(forDistance distance: Double) -> CGFloat {
        let d = min(max(distance.isFinite ? distance : 2, Self.minDistance), Self.maxDistance)
        let t = log(d / Self.minDistance) / log(Self.maxDistance / Self.minDistance)
        return Self.surroundMinRadius + CGFloat(t) * (surroundMaxRadius - Self.surroundMinRadius)
    }

    /// Radius in points to distance in metres; the inverse of the above.
    func surroundDistance(forRadius radius: CGFloat) -> Double {
        let span = surroundMaxRadius - Self.surroundMinRadius
        let t = Double(min(max((radius - Self.surroundMinRadius) / span, 0), 1))
        return Self.minDistance * pow(Self.maxDistance / Self.minDistance, t)
    }

    /// The point at `azimuth` degrees (0 up, positive clockwise) and `radius`.
    func point(azimuth: Double, radius: CGFloat) -> CGPoint {
        let radians = azimuth * .pi / 180
        return CGPoint(
            x: macCenter.x + CGFloat(sin(radians)) * radius,
            y: macCenter.y - CGFloat(cos(radians)) * radius)
    }

    /// Where a speaker is in the room, before clamping the card inside.
    func surroundPoint(azimuth: Double, distance: Double) -> CGPoint {
        point(azimuth: azimuth, radius: surroundRadius(forDistance: distance))
    }

    /// Card center for a Surround speaker, clamped so the card stays inside.
    func surroundCardCenter(azimuth: Double, distance: Double) -> CGPoint {
        clampedCardCenter(surroundPoint(azimuth: azimuth, distance: distance))
    }

    func clampedCardCenter(_ point: CGPoint) -> CGPoint {
        let minX = Self.cardInset.width + cardSize.width / 2
        let maxX = size.width - minX
        let minY = Self.cardInset.height + cardSize.height / 2
        let maxY = size.height - minY
        return CGPoint(
            x: minX <= maxX ? min(max(point.x, minX), maxX) : size.width / 2,
            y: minY <= maxY ? min(max(point.y, minY), maxY) : size.height / 2)
    }

    /// Azimuth (degrees, -180...180) and distance (metres) of a stage point.
    func surroundPlacement(at point: CGPoint) -> (azimuth: Double, distance: Double) {
        let dx = Double(point.x - macCenter.x)
        let dy = Double(point.y - macCenter.y)
        let azimuth = atan2(dx, -dy) * 180 / .pi
        let radius = CGFloat((dx * dx + dy * dy).squareRoot())
        return (Double(SurroundSpeaker.wrap(Float(azimuth))), surroundDistance(forRadius: radius))
    }

    /// Where the connector from the Mac meets the card centered at `center`:
    /// the point on the card's edge facing the Mac.
    func surroundConnectorEnd(cardCenter center: CGPoint) -> CGPoint {
        let dx = center.x - macCenter.x
        let dy = center.y - macCenter.y
        let halfW = cardSize.width / 2
        let halfH = cardSize.height / 2
        let sx = dx == 0 ? CGFloat.infinity : halfW / abs(dx)
        let sy = dy == 0 ? CGFloat.infinity : halfH / abs(dy)
        let s = min(sx, sy)
        guard s < 1 else { return center }
        return CGPoint(x: center.x - dx * s, y: center.y - dy * s)
    }

    /// The demo marker: on the guide circle at `azimuth`.
    func demoMarker(azimuth: Double) -> CGPoint {
        point(azimuth: azimuth, radius: guideRadius)
    }
}
