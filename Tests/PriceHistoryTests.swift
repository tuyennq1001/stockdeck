import XCTest
@testable import StockDeck

/// Covers the pure pairing of Yahoo v8 chart arrays (timestamps + closes with
/// possible nil holes) into chartable daily price points.
final class PriceHistoryTests: XCTestCase {

    func testPairsTimestampsWithCloses() {
        let points = PriceHistory.points(timestamps: [1000, 2000, 3000],
                                         closes: [10.0, 11.5, 12.0])
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].date, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(points[0].close, 10.0, accuracy: 1e-9)
        XCTAssertEqual(points[2].close, 12.0, accuracy: 1e-9)
    }

    func testSkipsNilCloses() {
        // Yahoo leaves nil holes on holidays/halts — they must not become zeros.
        let points = PriceHistory.points(timestamps: [1000, 2000, 3000],
                                         closes: [10.0, nil, 12.0])
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.map(\.close), [10.0, 12.0])
    }

    func testTruncatesToShortestArray() {
        // Defensive: mismatched lengths pair only the overlapping prefix.
        let points = PriceHistory.points(timestamps: [1000, 2000],
                                         closes: [10.0, 11.0, 12.0])
        XCTAssertEqual(points.count, 2)
        let points2 = PriceHistory.points(timestamps: [1000, 2000, 3000],
                                          closes: [10.0])
        XCTAssertEqual(points2.count, 1)
    }

    func testEmptyInputs() {
        XCTAssertTrue(PriceHistory.points(timestamps: [], closes: []).isEmpty)
    }

    func testPointsAreChronological() {
        let points = PriceHistory.points(timestamps: [3000, 1000, 2000],
                                         closes: [12.0, 10.0, 11.0])
        XCTAssertEqual(points.map(\.close), [10.0, 11.0, 12.0])
    }

    // MARK: - deriveMonthly (resample daily -> monthly, no second network call)

    private func makeCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testDeriveMonthlyTakesLastCloseOfEachMonth() {
        let cal = makeCalendar()
        let points = [
            PricePoint(date: date(2026, 1, 5, calendar: cal), close: 100),
            PricePoint(date: date(2026, 1, 20, calendar: cal), close: 110),
            PricePoint(date: date(2026, 2, 3, calendar: cal), close: 115),
            PricePoint(date: date(2026, 2, 27, calendar: cal), close: 120),
            PricePoint(date: date(2026, 3, 10, calendar: cal), close: 130),
        ]
        let monthly = PriceHistory.deriveMonthly(from: points, calendar: cal)

        XCTAssertEqual(monthly.count, 3)
        XCTAssertEqual(monthly[0].date, date(2026, 1, 1, calendar: cal))
        XCTAssertEqual(monthly[0].close, 110, accuracy: 0.001)
        XCTAssertEqual(monthly[1].date, date(2026, 2, 1, calendar: cal))
        XCTAssertEqual(monthly[1].close, 120, accuracy: 0.001)
        XCTAssertEqual(monthly[2].date, date(2026, 3, 1, calendar: cal))
        XCTAssertEqual(monthly[2].close, 130, accuracy: 0.001)
    }

    func testDeriveMonthlySortsInputAndFiltersNonFinite() {
        let cal = makeCalendar()
        let points = [
            PricePoint(date: date(2026, 2, 10, calendar: cal), close: .nan),
            PricePoint(date: date(2026, 1, 10, calendar: cal), close: 50),
            PricePoint(date: date(2026, 2, 20, calendar: cal), close: 60),
            PricePoint(date: date(2026, 1, 25, calendar: cal), close: 55),
        ]
        let monthly = PriceHistory.deriveMonthly(from: points, calendar: cal)

        XCTAssertEqual(monthly.count, 2)
        XCTAssertEqual(monthly[0].close, 55, accuracy: 0.001)
        XCTAssertEqual(monthly[1].close, 60, accuracy: 0.001)
    }

    func testDeriveMonthlyEmptyForEmptyInput() {
        XCTAssertTrue(PriceHistory.deriveMonthly(from: [], calendar: makeCalendar()).isEmpty)
    }
}
