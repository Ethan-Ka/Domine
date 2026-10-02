import CoreGraphics

/// Geometry of the stage, taken from docs/mockups/Main.dc.html (616 x 320
/// design size) and stretched to the real size.
struct StageLayout: Equatable, Sendable {
    let size: CGSize

    static let designSize = CGSize(width: 616, height: 320)
    static let cardInset = CGSize(width: 20, height: 16)

    static let cardSize = CGSize(width: 176, height: 100)
    private var cardSize: CGSize { Self.cardSize }

    /// Center of the Mac symbol; the mockup puts it slightly above middle.
    var macCenter: CGPoint {
        CGPoint(x: size.width / 2, y: size.height * 150 / Self.designSize.height)
    }

    var guideRadius: CGFloat {
        118 * min(size.width / Self.designSize.width, size.height / Self.designSize.height)
    }

    func cardCenter(_ position: SpeakerPosition) -> CGPoint {
        let halfW = cardSize.width / 2
        let halfH = cardSize.height / 2
        let x = position.isLeft
            ? Self.cardInset.width + halfW
            : size.width - Self.cardInset.width - halfW
        let y = position.isFront
            ? Self.cardInset.height + halfH
            : size.height - Self.cardInset.height - halfH
        return CGPoint(x: x, y: y)
    }

    /// Where the connector leaves the Mac: just outside the symbol, on the
    /// line from the Mac's center to the card.
    func connectorStart(_ position: SpeakerPosition) -> CGPoint {
        let end = connectorEnd(position)
        let dx = end.x - macCenter.x
        let dy = end.y - macCenter.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > Self.macClearance else { return macCenter }
        let scale = Self.macClearance / length
        return CGPoint(x: macCenter.x + dx * scale, y: macCenter.y + dy * scale)
    }

    /// Space kept between the banner and the rear cards.
    static let bannerGap: CGFloat = 10
    /// Widest the banner gets on a large stage (the mockup's width).
    static let bannerMaxWidth: CGFloat = 316

    /// The banner sits between the two rear cards, bottom-aligned with
    /// them, so it never covers their text.
    var bannerWidth: CGFloat {
        let between = size.width - 2 * (Self.cardInset.width + cardSize.width + Self.bannerGap)
        return max(0, min(Self.bannerMaxWidth, between))
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
}
