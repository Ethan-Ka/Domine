import Testing
@testable import Domine

struct VerticalGainSliderTests {
    @Test func yMapsToDb() {
        let r = -12.0...12.0
        #expect(VerticalGainSlider.value(forY: -50, height: 114, range: r) == 12)
        #expect(VerticalGainSlider.value(forY: 500, height: 114, range: r) == -12)
        #expect(VerticalGainSlider.value(forY: 57, height: 114, range: r) == 0)
    }
}
