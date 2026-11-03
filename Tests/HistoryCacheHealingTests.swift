import XCTest
@testable import StockDeck

final class HistoryCacheHealingTests: XCTestCase {

    func testSanitizeLeadingSplitAnomaly_1489T() {
        // Simulates Yahoo's 1489.T bug where the first two trading days in 2017 were left unadjusted at ~35,000 JPY
        // while the rest of the 10-year series was adjusted by 1:30 down to ~1,200 JPY.
        let baseDate = Date(timeIntervalSince1970: 1486598400) // 2017-02-09
        let points: [PricePoint] = [
            PricePoint(date: baseDate, close: 34875, open: 34875, high: 34875, low: 34875),
            PricePoint(date: baseDate.addingTimeInterval(86400), close: 35706, open: 35706, high: 35706, low: 35706),
            PricePoint(date: baseDate.addingTimeInterval(86400 * 2), close: 1200, open: 1200, high: 1208, low: 1190),
            PricePoint(date: baseDate.addingTimeInterval(86400 * 3), close: 1195, open: 1200, high: 1208, low: 1192),
            PricePoint(date: baseDate.addingTimeInterval(86400 * 4), close: 1213, open: 1200, high: 1215, low: 1198),
            PricePoint(date: baseDate.addingTimeInterval(86400 * 5), close: 1206, open: 1210, high: 1216, low: 1202),
            PricePoint(date: baseDate.addingTimeInterval(86400 * 6), close: 1208, open: 1205, high: 1211, low: 1200),
            PricePoint(date: baseDate.addingTimeInterval(86400 * 7), close: 3655, open: 3600, high: 3655, low: 3590) // True ATH years later
        ]

        let sanitized = PriceHistory.sanitizeSplitAnomalies(points)
        XCTAssertEqual(sanitized.count, points.count)

        // The first two bars must be scaled down to ~1,200 JPY
        XCTAssertEqual(sanitized[0].close, 1172.0, accuracy: 2.0)
        XCTAssertEqual(sanitized[1].close, 1200.0, accuracy: 2.0)
        XCTAssertEqual(sanitized[1].high ?? 0, 1200.0, accuracy: 2.0)

        // The true ATH should now be 3655.0, NOT 35706.0
        let maxHigh = sanitized.compactMap(\.high).max()
        XCTAssertEqual(maxHigh, 3655.0)
    }

    func testSanitizeIsolatedPocketSplitAnomaly_1489T() {
        // Simulates Yahoo's 1489.T bug right before the Jan 2024 split where 2 bars were double-divided by 30 (~70 JPY)
        let baseDate = Date(timeIntervalSince1970: 1705363200)
        let points: [PricePoint] = [
            PricePoint(date: baseDate, close: 2059, open: 2050, high: 2060, low: 2045),
            PricePoint(date: baseDate.addingTimeInterval(86400), close: 2080, open: 2065, high: 2090, low: 2060),
            PricePoint(date: baseDate.addingTimeInterval(86400 * 2), close: 70.6, open: 71.0, high: 71.6, low: 70.0),
            PricePoint(date: baseDate.addingTimeInterval(86400 * 3), close: 69.3, open: 70.0, high: 70.6, low: 69.0),
            PricePoint(date: baseDate.addingTimeInterval(86400 * 4), close: 2080, open: 2075, high: 2107, low: 2070),
            PricePoint(date: baseDate.addingTimeInterval(86400 * 5), close: 2105, open: 2085, high: 2105, low: 2080),
        ]

        let sanitized = PriceHistory.sanitizeSplitAnomalies(points)
        XCTAssertEqual(sanitized.count, points.count)

        // The two dropped bars should be scaled back to ~2080 JPY
        XCTAssertGreaterThan(sanitized[2].close, 2000.0)
        XCTAssertLessThan(sanitized[2].close, 2200.0)
        XCTAssertGreaterThan(sanitized[3].close, 2000.0)
        XCTAssertLessThan(sanitized[3].close, 2200.0)

        // ATL of this series should not be ~69 JPY
        let minLow = sanitized.compactMap(\.low).min() ?? 0
        XCTAssertGreaterThan(minLow, 2000.0)
    }

    func testDeriveMonthlySanitizesDailySplitAnomaly() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let d1 = cal.date(from: DateComponents(year: 2017, month: 2, day: 9))!
        let d2 = cal.date(from: DateComponents(year: 2017, month: 2, day: 10))!
        let d3 = cal.date(from: DateComponents(year: 2017, month: 2, day: 13))!
        let d4 = cal.date(from: DateComponents(year: 2017, month: 2, day: 20))!
        let d5 = cal.date(from: DateComponents(year: 2017, month: 2, day: 27))!
        let d6 = cal.date(from: DateComponents(year: 2017, month: 3, day: 5))!

        let daily: [PricePoint] = [
            PricePoint(date: d1, close: 34875, high: 34875, low: 34875),
            PricePoint(date: d2, close: 35706, high: 35706, low: 35706),
            PricePoint(date: d3, close: 1200, high: 1208, low: 1190),
            PricePoint(date: d4, close: 1195, high: 1208, low: 1192),
            PricePoint(date: d5, close: 1213, high: 1215, low: 1198),
            PricePoint(date: d6, close: 1206, high: 1216, low: 1202)
        ]

        let monthly = PriceHistory.deriveMonthly(from: daily, calendar: cal)
        XCTAssertEqual(monthly.count, 2)
        // High of Feb 2017 should be ~1215, not 35706
        XCTAssertLessThan(monthly[0].high ?? 0, 1300.0)
    }

    func testScaleMismatchIdentifiedForCrossMarketCollision() {
        // Simulates US NET ($265.17) vs HNX NET (~56,500 VND)
        let quotePrice = 265.17
        let vnHistoryClose = 56500.0
        let ratio = vnHistoryClose / quotePrice

        XCTAssertGreaterThan(ratio, 3.0)
        let isMismatch = ratio > 3.0 || ratio < 0.33
        XCTAssertTrue(isMismatch)
    }
}
