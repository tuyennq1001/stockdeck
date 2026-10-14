import XCTest
@testable import StockDeck

final class ParseNumberTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")
    private let vi = Locale(identifier: "vi_VN")

    func testGroupedEnglishValue() {
        XCTAssertEqual(StorageService.parseNumber("30,647.00", locale: en), 30647.0)
    }

    func testGroupedEuropeanValue() {
        XCTAssertEqual(StorageService.parseNumber("30.647,00", locale: de), 30647.0)
        XCTAssertEqual(StorageService.parseNumber("30.647,00", locale: vi), 30647.0)
    }

    func testPlainAndDecimalInput() {
        XCTAssertEqual(StorageService.parseNumber("30647", locale: en), 30647.0)
        XCTAssertEqual(StorageService.parseNumber("0,5", locale: en), 0.5)
        XCTAssertEqual(StorageService.parseNumber("0.5", locale: de), 0.5)
        XCTAssertEqual(StorageService.parseNumber("12.5", locale: en), 12.5)
    }

    func testSingleSeparatorGrouping() {
        XCTAssertEqual(StorageService.parseNumber("1,234", locale: en), 1234.0)
        XCTAssertEqual(StorageService.parseNumber("1.234", locale: de), 1234.0)
        XCTAssertEqual(StorageService.parseNumber("1,234,567", locale: en), 1234567.0)
    }

    func testInvalidInput() {
        XCTAssertNil(StorageService.parseNumber("", locale: en))
        XCTAssertNil(StorageService.parseNumber("abc", locale: en))
        XCTAssertNil(StorageService.parseNumber("1.2.3,4,5x", locale: en))
    }

    func testRoundTripWithFormatNumber() {
        for locale in [en, de, vi] {
            for value in [30647.0, 1234.56, 0.1234, 999.0, 1_234_567.89] {
                let decimals = value < 1 ? 4 : 2
                let text = StorageService.formatNumber(value, decimals: decimals, locale: locale)
                let parsed = StorageService.parseNumber(text, locale: locale)
                XCTAssertNotNil(parsed, "\(text) in \(locale.identifier)")
                XCTAssertEqual(parsed ?? 0, value, accuracy: 0.0001, "\(text) in \(locale.identifier)")
            }
        }
    }
}
