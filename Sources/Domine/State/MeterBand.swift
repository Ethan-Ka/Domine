/// Color band of one meter segment (docs/mockups/README.md): with 16 segments,
/// 1...11 are green, 12...14 yellow, 15...16 red. For other counts the top 2
/// are red and the 3 below them yellow.
enum MeterBand: Sendable, Equatable {
    case green
    case yellow
    case red

    static let segmentCount = 16
    static let redCount = 2
    static let yellowCount = 3

    /// Band for a 1-based segment index. Indexes below 1 are treated as 1 and
    /// indexes above `count` as `count`.
    init(segment: Int, count: Int = MeterBand.segmentCount) {
        let index = min(max(segment, 1), max(count, 1))
        if index > count - Self.redCount {
            self = .red
        } else if index > count - Self.redCount - Self.yellowCount {
            self = .yellow
        } else {
            self = .green
        }
    }
}
