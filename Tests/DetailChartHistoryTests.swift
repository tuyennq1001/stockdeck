import XCTest
@testable import StockDeck

final class DetailChartHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private func point(_ daysAgo: Double, _ price: Double) -> PricePoint {
        PricePoint(date: now.addingTimeInterval(-daysAgo * 86400), close: price)
    }

    func testRangeKeepsBaselineAndPrefersFresherDailyHistory() {
        let daily = [point(60, 5), point(40, 10), point(20, 20), point(0, 30)]
        let input = PriceChartCard.HistoryInput(symbol: "VGT", range: .month,
            daily: daily, watchlist: [point(60, 1), point(9, 2)], full: [], intraday: [])
        XCTAssertEqual(PriceChartCard.computeHistory(input, now: now), Array(daily.dropFirst()))
    }

    func testSevenYearsAndTenYearsRanges() {
        XCTAssertEqual(PriceChartCard.ChartRange.sevenYears.rawValue, "7Y")
        XCTAssertEqual(PriceChartCard.ChartRange.tenYears.rawValue, "10Y")
        XCTAssertEqual(PriceChartCard.ChartRange.sevenYears.days, 365 * 7)
        XCTAssertEqual(PriceChartCard.ChartRange.tenYears.days, 365 * 10)
        XCTAssertFalse(PriceChartCard.ChartRange.allCases.contains(where: { $0.rawValue == "7D" }))
        XCTAssertEqual(PriceChartCard.ChartRange.sevenYears.changeLabel(isVi: false), "past 7Y")
        XCTAssertEqual(PriceChartCard.ChartRange.sevenYears.changeLabel(isVi: true), "7 năm qua")
        XCTAssertEqual(PriceChartCard.ChartRange.tenYears.changeLabel(isVi: false), "past 10Y")
        XCTAssertEqual(PriceChartCard.ChartRange.tenYears.changeLabel(isVi: true), "10 năm qua")

        let cal = Calendar.current
        let testDate = Date(timeIntervalSince1970: 1_700_000_000)
        let expected7Y = cal.date(byAdding: .year, value: -7, to: testDate)
        let expected10Y = cal.date(byAdding: .year, value: -10, to: testDate)
        XCTAssertEqual(PriceChartCard.ChartRange.sevenYears.startDate(from: testDate, calendar: cal), expected7Y)
        XCTAssertEqual(PriceChartCard.ChartRange.tenYears.startDate(from: testDate, calendar: cal), expected10Y)
    }

    func testAllRangeUsesFullHistoryAndDetectsMiddlePointChanges() {
        let full = [point(1000, 10), point(500, 20), point(0, 30)]
        let input = PriceChartCard.HistoryInput(symbol: "VGT", range: .all,
            daily: [point(10, 29), point(0, 30)], watchlist: [], full: full, intraday: [])
        var changed = full
        changed[1] = point(500, 25)
        let next = PriceChartCard.HistoryInput(symbol: "VGT", range: .all,
            daily: input.daily, watchlist: [], full: changed, intraday: [])
        XCTAssertNotEqual(input, next)
        XCTAssertEqual(PriceChartCard.computeHistory(input, now: now), full)
        XCTAssertEqual(PriceChartCard.computeHistory(next, now: now), changed)
    }

    func testNearestPointMatchesLinearLookupIncludingBoundariesAndTies() {
        let points = [point(10, 10), point(6, 20), point(2, 30)]
        XCTAssertNil(PriceHistory.nearestPoint(to: now, in: []))
        for daysAgo in stride(from: 15.0, through: -5.0, by: -0.5) {
            let date = now.addingTimeInterval(-daysAgo * 86400)
            let expected = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
            XCTAssertEqual(PriceHistory.nearestPoint(to: date, in: points), expected)
        }
    }
}
