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

    func testRecentIPOHistoryPrefersDailyOverDerivedMonthlyForSixMonthsAndAll() {
        // Stock listed 70 days ago (e.g. SKHY). Daily has 70 points.
        var dailyPoints: [PricePoint] = []
        for i in (0...70).reversed() {
            dailyPoints.append(point(Double(i), Double(100 + i)))
        }
        // Derived monthly has 3 points; due to calendar month-start, the earliest point is 78 days ago.
        let derivedMonthly = [point(78, 100), point(48, 120), point(18, 150), point(0, 170)]

        // 6M: cutoff is ~180 days ago. Daily has 70 days.
        // Should keep all 71 daily points, NOT fall back to 4 monthly points.
        let input6M = PriceChartCard.HistoryInput(symbol: "SKHY", range: .sixMonths,
            daily: dailyPoints, watchlist: [], full: derivedMonthly, intraday: [])
        let history6M = PriceChartCard.computeHistory(input6M, now: now)
        XCTAssertEqual(history6M.count, dailyPoints.count)
        XCTAssertEqual(history6M.first?.date, dailyPoints.first?.date)

        // All: Derived monthly does NOT extend > 35 days further back than daily.
        // Should keep high-resolution daily points.
        let inputAll = PriceChartCard.HistoryInput(symbol: "SKHY", range: .all,
            daily: dailyPoints, watchlist: [], full: derivedMonthly, intraday: [])
        let historyAll = PriceChartCard.computeHistory(inputAll, now: now)
        XCTAssertEqual(historyAll.count, dailyPoints.count)
        XCTAssertEqual(historyAll.first?.date, dailyPoints.first?.date)
    }

    func testMissingDailyFallsBackToFull() {
        let full = [point(300, 50), point(150, 75), point(0, 100)]
        let input = PriceChartCard.HistoryInput(symbol: "OLD", range: .sixMonths,
            daily: [], watchlist: [], full: full, intraday: [])
        let history = PriceChartCard.computeHistory(input, now: now)
        XCTAssertEqual(history.count, 3) // Baseline inserted if cutoff is within
    }

    func testIsRangeAvailableDisablesInsufficientHistoryForRecentIPO() {
        // Stock listed 98 calendar days ago (approx. 70 trading days, e.g. SKHY).
        var dailyPoints: [PricePoint] = []
        for i in (0...98).reversed() {
            dailyPoints.append(point(Double(i), Double(100 + i)))
        }
        let derivedMonthly = [point(98, 100), point(68, 120), point(38, 150), point(0, 170)]

        XCTAssertTrue(PriceChartCard.isRangeAvailable(.month, daily: dailyPoints, watchlist: [], full: derivedMonthly, now: now))
        XCTAssertTrue(PriceChartCard.isRangeAvailable(.threeMonths, daily: dailyPoints, watchlist: [], full: derivedMonthly, now: now))
        XCTAssertFalse(PriceChartCard.isRangeAvailable(.sixMonths, daily: dailyPoints, watchlist: [], full: derivedMonthly, now: now))
        XCTAssertFalse(PriceChartCard.isRangeAvailable(.ytd, daily: dailyPoints, watchlist: [], full: derivedMonthly, now: now))
        XCTAssertFalse(PriceChartCard.isRangeAvailable(.year, daily: dailyPoints, watchlist: [], full: derivedMonthly, now: now))
        XCTAssertFalse(PriceChartCard.isRangeAvailable(.threeYears, daily: dailyPoints, watchlist: [], full: derivedMonthly, now: now))
        XCTAssertFalse(PriceChartCard.isRangeAvailable(.fiveYears, daily: dailyPoints, watchlist: [], full: derivedMonthly, now: now))
        XCTAssertFalse(PriceChartCard.isRangeAvailable(.sevenYears, daily: dailyPoints, watchlist: [], full: derivedMonthly, now: now))
        XCTAssertFalse(PriceChartCard.isRangeAvailable(.tenYears, daily: dailyPoints, watchlist: [], full: derivedMonthly, now: now))
        XCTAssertTrue(PriceChartCard.isRangeAvailable(.all, daily: dailyPoints, watchlist: [], full: derivedMonthly, now: now))
    }
}
