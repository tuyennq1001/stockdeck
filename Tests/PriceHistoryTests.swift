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

    func testPairsTimestampsWithVolumes() {
        let points = PriceHistory.points(timestamps: [1000, 2000, 3000],
                                         closes: [10.0, 11.5, 12.0],
                                         volumes: [100.0, 250.0, nil])
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].volume, 100.0)
        XCTAssertEqual(points[1].volume, 250.0)
        XCTAssertNil(points[2].volume)
    }

    func testDeriveMonthlyAggregatesVolume() {
        let cal = makeCalendar()
        let points = [
            PricePoint(date: date(2026, 1, 5, calendar: cal), close: 100, volume: 500),
            PricePoint(date: date(2026, 1, 20, calendar: cal), close: 110, volume: 300),
            PricePoint(date: date(2026, 2, 3, calendar: cal), close: 115, volume: 400),
            PricePoint(date: date(2026, 2, 27, calendar: cal), close: 120, volume: 600),
        ]
        let monthly = PriceHistory.deriveMonthly(from: points, calendar: cal)

        XCTAssertEqual(monthly.count, 2)
        XCTAssertEqual(monthly[0].close, 110, accuracy: 0.001)
        XCTAssertEqual(monthly[0].volume, 800)
        XCTAssertEqual(monthly[1].close, 120, accuracy: 0.001)
        XCTAssertEqual(monthly[1].volume, 1000)
    }

    func testVolumeMetricsCategoriesAndTitles() throws {
        XCTAssertEqual(WatchlistMetric.volume50d.title, "50D Vol")
        XCTAssertEqual(WatchlistMetric.volume50w.title, "50W Vol")
        XCTAssertTrue(WatchlistMetric.volume50d.isChart)
        XCTAssertTrue(WatchlistMetric.volume50w.isChart)

        XCTAssertEqual(PortfolioColumnMetric.volume50d.title, "50D Vol")
        XCTAssertEqual(PortfolioColumnMetric.volume50w.title, "50W Vol")
        XCTAssertEqual(PortfolioColumnMetric.volume50d.category, .chart)
        XCTAssertEqual(PortfolioColumnMetric.volume50w.category, .chart)

        // Test backward-compatible JSON decoding
        let legacyJson1 = "\"volume20w\"".data(using: .utf8)!
        let legacyJson2 = "\"volume7d\"".data(using: .utf8)!
        let legacyJson3 = "\"volume30d\"".data(using: .utf8)!
        let newJsonW = "\"volume50w\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(WatchlistMetric.self, from: legacyJson1), .volume50w)
        XCTAssertEqual(try JSONDecoder().decode(WatchlistMetric.self, from: legacyJson2), .volume50d)
        XCTAssertEqual(try JSONDecoder().decode(WatchlistMetric.self, from: legacyJson3), .volume50d)
        XCTAssertEqual(try JSONDecoder().decode(WatchlistMetric.self, from: newJsonW), .volume50w)
        XCTAssertEqual(try JSONDecoder().decode(PortfolioColumnMetric.self, from: legacyJson1), .volume50w)
        XCTAssertEqual(try JSONDecoder().decode(PortfolioColumnMetric.self, from: legacyJson2), .volume50d)
        XCTAssertEqual(try JSONDecoder().decode(PortfolioColumnMetric.self, from: legacyJson3), .volume50d)
        XCTAssertEqual(try JSONDecoder().decode(PortfolioColumnMetric.self, from: newJsonW), .volume50w)
    }

    func testComputeHistoryPrefersSeriesWithVolume() {
        let cal = makeCalendar()
        let now = date(2026, 6, 1, calendar: cal)
        let d1 = date(2026, 5, 20, calendar: cal)
        let d2 = date(2026, 5, 25, calendar: cal)

        // daily has volume
        let dailyWithVol = [
            PricePoint(date: d1, close: 100, volume: 5000),
            PricePoint(date: d2, close: 102, volume: 6000)
        ]
        // watchlist lacks volume
        let watchlistWithoutVol = [
            PricePoint(date: d1, close: 100, volume: nil),
            PricePoint(date: d2, close: 102, volume: nil)
        ]

        let input = PriceChartCard.HistoryInput(
            symbol: "TEST",
            range: .month,
            daily: dailyWithVol,
            watchlist: watchlistWithoutVol,
            full: [],
            intraday: []
        )

        let result = PriceChartCard.computeHistory(input, now: now)
        XCTAssertTrue(result.contains(where: { ($0.volume ?? 0) > 0 }))
        XCTAssertEqual(result.last?.volume, 6000)
    }

    func testVolumeCardWarmsUpMAAndAlignsPeriods() {
        let cal = makeCalendar()
        let now = date(2026, 6, 1, calendar: cal)

        // Generate 400 days of daily points (~1.1 years)
        var points: [PricePoint] = []
        for i in (0..<400).reversed() {
            guard let d = cal.date(byAdding: .day, value: -i, to: now) else { continue }
            points.append(PricePoint(date: d, close: 100, open: 99, volume: 1000))
        }

        // Test Daily timeframe
        let dailyInput = VolumeChartCard.HistoryInput(
            symbol: "VOO",
            timeframe: .daily,
            daily: points,
            watchlist: [],
            full: []
        )
        let dailyResult = VolumeChartCard.processVolumeData(input: dailyInput)
        XCTAssertEqual(dailyResult.points.count, 50)
        XCTAssertEqual(dailyResult.latestVolume, 1000)
        XCTAssertEqual(dailyResult.latestValue, 100_000)
        XCTAssertEqual(dailyResult.latestMA20, 100_000)
        XCTAssertEqual(dailyResult.points.first?.index, 0)
        XCTAssertEqual(dailyResult.points.last?.index, 49)
        XCTAssertEqual(dailyResult.points.first?.ma, 100_000)

        // Test Weekly timeframe
        let weeklyInput = VolumeChartCard.HistoryInput(
            symbol: "VOO",
            timeframe: .weekly,
            daily: points,
            watchlist: [],
            full: []
        )
        let weeklyResult = VolumeChartCard.processVolumeData(input: weeklyInput)
        XCTAssertEqual(weeklyResult.points.count, 52)
        XCTAssertEqual(weeklyResult.points.first?.index, 0)
        XCTAssertEqual(weeklyResult.points.last?.index, 51)
        XCTAssertNotNil(weeklyResult.points.first?.ma)
        XCTAssertGreaterThan(weeklyResult.latestMA20, 0)
    }
}
