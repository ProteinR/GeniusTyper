import XCTest
@testable import ProteinKit

final class LightSliderTests: XCTestCase {
    // A 116 pt slider: the knob is 16 pt, so its centre runs from x = 8 to x = 108 (100 pt of track).
    func testValueFollowsTheKnobCentre() {
        XCTAssertEqual(LightSlider.value(atX: 8, width: 116, range: 0...100, step: 1), 0)
        XCTAssertEqual(LightSlider.value(atX: 58, width: 116, range: 0...100, step: 1), 50)
        XCTAssertEqual(LightSlider.value(atX: 108, width: 116, range: 0...100, step: 1), 100)
    }

    func testValueIsClampedOutsideTheTrack() {
        XCTAssertEqual(LightSlider.value(atX: -40, width: 116, range: 6...16, step: 1), 6)
        XCTAssertEqual(LightSlider.value(atX: 400, width: 116, range: 6...16, step: 1), 16)
    }

    func testValueSnapsToStep() {
        XCTAssertEqual(LightSlider.value(atX: 21, width: 116, range: 0...100, step: 5), 15)
        XCTAssertEqual(LightSlider.value(atX: 8 + 33.4, width: 116, range: 0...1, step: 0.25), 0.25, accuracy: 1e-9)
    }

    func testZeroWidthDoesNotDivideByZero() {
        let value = LightSlider.value(atX: 0, width: 0, range: 0...10, step: 1)
        XCTAssertTrue((0...10).contains(value))
    }
}

final class AboutTests: XCTestCase {
    func testAuthorLink() {
        XCTAssertEqual(Links.author.absoluteString, "https://github.com/ProteinR")
        XCTAssertEqual("https://" + Links.authorTitle, Links.author.absoluteString)
    }

    func testPackageStringsHaveEnglish() throws {
        let bundle = Bundle.module
        let en = try XCTUnwrap(bundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(en.localizedString(forKey: "Вкл.", value: nil, table: nil), "On")
        XCTAssertEqual(en.localizedString(forKey: "Выкл.", value: nil, table: nil), "Off")
        XCTAssertEqual(en.localizedString(forKey: "Автор %@ на GitHub", value: nil, table: nil), "%@'s author on GitHub")
    }
}
