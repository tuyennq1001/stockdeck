import XCTest
@testable import StockDeck

final class LightweightChartTimeControlsTests: XCTestCase {
    // Synthetic OHLC history is used only to check aggregation and date boundaries.
    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testHourlyBucketsFollowSessionOpenAndPreserveOHLCV() {
        let start = date(2025, 3, 10, hour: 9, minute: 30)
        let points = (0...6).map { index in
            PricePoint(date: start.addingTimeInterval(Double(index) * 3600), close: 100 + Double(index),
                       open: 99 + Double(index), high: 102 + Double(index), low: 98 + Double(index), volume: 10)
        }
        let four = LightweightChartMath.aggregate(points, interval: .fourHours, symbol: "AAPL")
        XCTAssertEqual(four.count, 2)
        XCTAssertEqual(four[0].date, start)
        XCTAssertEqual(four[0].open, 99)
        XCTAssertEqual(four[0].high, 105)
        XCTAssertEqual(four[0].low, 98)
        XCTAssertEqual(four[0].close, 103)
        XCTAssertEqual(four[0].volume, 40)
        XCTAssertEqual(four[1].date, start.addingTimeInterval(14400))
        let six = LightweightChartMath.aggregate(points, interval: .sixHours, symbol: "AAPL")
        XCTAssertEqual(six.count, 2)
        XCTAssertEqual(six[0].close, 105)
        XCTAssertEqual(six[0].volume, 60)
    }

    func testThreeAndSixMonthCandlesUseCalendarBoundaries() {
        let points = [2, 3, 5, 8].enumerated().map { index, month in
            PricePoint(date: date(2025, month, 15), close: 100 + Double(index), volume: 10)
        }
        let quarter = LightweightChartMath.aggregate(points, interval: .quarter, symbol: "AAPL")
        XCTAssertEqual(quarter.map(\.close), [101, 102, 103])
        XCTAssertEqual(quarter.first?.date, date(2025, 1, 1))
        let half = LightweightChartMath.aggregate(points, interval: .halfYear, symbol: "AAPL")
        XCTAssertEqual(half.map(\.close), [102, 103])
        XCTAssertEqual(half.last?.date, date(2025, 7, 1))
    }

    func testIntradayPayloadKeepsDistinctTimesAndUpperRangeBound() {
        let start = date(2025, 3, 10, hour: 9, minute: 30)
        let points = (0..<20).map { PricePoint(date: start.addingTimeInterval(Double($0) * 300), close: Double(100 + $0)) }
        let payload = LightweightChartMath.payload(points: points, interval: .fiveMinutes, symbol: "AAPL",
            currency: "USD", periods: [:], visibleFrom: start, visibleTo: start.addingTimeInterval(3600))
        XCTAssertEqual(Set(payload.bars.map(\.time)).count, 20)
        XCTAssertEqual(payload.visibleTo, String(Int(start.timeIntervalSince1970 + 3600)))
        XCTAssertEqual(payload.timeZone, "America/New_York")
    }

    func testCustomRangeRejectsInvalidDatesAndIncludesEndDay() throws {
        XCTAssertNil(LightweightCustomRange(from: "2025-02-30", to: "2025-03-01").dates(symbol: "AAPL"))
        XCTAssertNil(LightweightCustomRange(from: "2025-03-11", to: "2025-03-10").dates(symbol: "AAPL"))
        let range = LightweightCustomRange(from: "2025-03-09", to: "2025-03-09")
        let bounds = try XCTUnwrap(range.dates(symbol: "AAPL"))
        XCTAssertEqual(bounds.0, date(2025, 3, 9))
        XCTAssertEqual(bounds.1, date(2025, 3, 10).addingTimeInterval(-1))
        XCTAssertEqual(range.automaticInterval(symbol: "AAPL"), .day)
    }

    func testCustomSelectionSurvivesRelaunchAndSymbolChange() {
        let suite = "TimeControls-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = LightweightChartViewSelection(range: "Custom", interval: .quarter,
            customRange: .init(from: "2020-01-01", to: "2025-10-01"))
        LightweightChartViewSelectionStore.save(selection, surface: .superchart, defaults: defaults)
        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "AAPL", surface: .superchart, defaults: defaults), selection)
        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "MSFT", surface: .superchart, defaults: defaults), selection)
        XCTAssertEqual(LightweightChartRangePreset.oneDay.automaticInterval, .fiveMinutes)
        XCTAssertEqual(LightweightChartRangePreset.fiveDays.automaticInterval, .thirtyMinutes)
    }

    func testPayloadCacheIncludesCustomEndDate() {
        let points = [PricePoint(date: date(2025, 1, 1), close: 100), PricePoint(date: date(2025, 6, 1), close: 120)]
        func payload(to end: Date) -> Data? {
            LightweightChartMath.encodedPayload(points: points, interval: .day, symbol: "AAPL", currency: "USD",
                periods: [:], visibleFrom: points.first?.date, markers: [], targetPrice: nil, visibleTo: end)
        }
        XCTAssertNotEqual(payload(to: date(2025, 2, 1)), payload(to: date(2025, 4, 1)))
    }

    func testIntradayRequestKeepsMarketIdentity() {
        XCTAssertEqual(SuperchartIntradayLoader.requestSymbol(for: "ACB"), "ACB.VN")
        XCTAssertEqual(SuperchartIntradayLoader.requestSymbol(for: "NET.HN"), "NET.VN")
        XCTAssertEqual(SuperchartIntradayLoader.requestSymbol(for: "7203"), "7203.T")
        XCTAssertEqual(SuperchartIntradayLoader.requestSymbol(for: "BTCUSDT"), "BTC-USD")
        XCTAssertEqual(SuperchartIntradayLoader.requestSymbol(for: "AAPL"), "AAPL")
    }
}
