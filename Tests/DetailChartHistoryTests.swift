import XCTest
@testable import StockDeck

final class DetailChartHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private func point(_ daysAgo: Double, _ price: Double) -> PricePoint {
        PricePoint(date: now.addingTimeInterval(-daysAgo * 86400), close: price)
    }

    func testRangeKeepsBaselineAndPrefersFresherDailyHistory() {
        let daily = [point(12, 10), point(8, 20), point(3, 30), point(0, 40)]
        let input = PriceChartCard.HistoryInput(symbol: "VGT", range: .week,
            daily: daily, watchlist: [point(12, 1), point(9, 2)], full: [], intraday: [])
        XCTAssertEqual(PriceChartCard.computeHistory(input, now: now), Array(daily.dropFirst()))
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
