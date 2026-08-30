import XCTest
@testable import StockDeck

final class TodayPerformanceTests: XCTestCase {
    private func input(
        quantity: Double,
        regularPrice: Double,
        previousClose: Double,
        rate: Double = 1,
        leverage: Double? = nil
    ) -> TodayPerformance.Input {
        TodayPerformance.Input(
            holding: Holding(symbol: "X", quantity: quantity, avgPrice: 0, leverage: leverage),
            regularPrice: regularPrice,
            previousClose: previousClose,
            rate: rate
        )
    }

    func testTotalsUsePreviousCloseQuantityAndFxRate() {
        let result = TodayPerformance.totals([
            input(quantity: 10, regularPrice: 110, previousClose: 100, rate: 0.9),
            input(quantity: 5, regularPrice: 48, previousClose: 50, rate: 2),
        ])

        XCTAssertEqual(result.gain, 70, accuracy: 1e-9)
        XCTAssertEqual(result.percent, 70 / 1400 * 100, accuracy: 1e-9)
    }

    func testPercentUsesPreviousClosePortfolioValue() {
        let result = TodayPerformance.totals([
            input(quantity: 10, regularPrice: 110, previousClose: 100),
        ])

        XCTAssertEqual(result.gain, 100, accuracy: 1e-9)
        XCTAssertEqual(result.percent, 10, accuracy: 1e-9)
    }

    func testLeverageAppliesToGainAndPreviousCloseValue() {
        let result = TodayPerformance.totals([
            input(quantity: 10, regularPrice: 110, previousClose: 100, leverage: 3),
        ])

        XCTAssertEqual(result.gain, 300, accuracy: 1e-9)
        XCTAssertEqual(result.percent, 10, accuracy: 1e-9)
    }

    func testEmptyPortfolioReturnsZero() {
        let result = TodayPerformance.totals([])
        XCTAssertEqual(result.gain, 0)
        XCTAssertEqual(result.percent, 0)
    }

    func testWeekendClosedMarketsDoNotContributeToGain() {
        // Stock holding with isMarketActiveToday = false (weekend closed)
        let stockInput = TodayPerformance.Input(
            holding: Holding(symbol: "AAPL", quantity: 10, avgPrice: 100),
            regularPrice: 150,
            previousClose: 100,
            rate: 1.0,
            isMarketActiveToday: false
        )
        // Crypto holding with isMarketActiveToday = true (24/7 active)
        let cryptoInput = TodayPerformance.Input(
            holding: Holding(symbol: "BTCUSDT", quantity: 1, avgPrice: 1000),
            regularPrice: 950,
            previousClose: 1000,
            rate: 1.0,
            isMarketActiveToday: true
        )

        let result = TodayPerformance.totals([stockInput, cryptoInput])
        // Stock gain is 0 (closed). Crypto gain is -50. Total gain = -50.
        XCTAssertEqual(result.gain, -50, accuracy: 1e-9)
        // Previous close value = (100 * 10) + (1000 * 1) = 2000.
        // Percent = (-50 / 2000) * 100 = -2.5%.
        XCTAssertEqual(result.percent, -2.5, accuracy: 1e-9)
    }

    func testMarketCategoryTradingDayDetection() {
        let isoFormatter = ISO8601DateFormatter()

        // 1. Monday early morning at 5:37 AM JST (2026-08-31T05:37:56+09:00)
        // - In NY: Sunday Aug 30, 16:37 EDT -> US is CLOSED (Sunday)
        // - In Tokyo: Monday Aug 31, 05:37 JST -> JP is CLOSED (before 09:00 open)
        // - In VN: Monday Aug 31, 03:37 ICT -> VN is CLOSED (before 09:00 open)
        // - Crypto: ACTIVE (24/7)
        let mondayEarlyJST = isoFormatter.date(from: "2026-08-31T05:37:56+09:00")!
        XCTAssertFalse(MarketCategory.us.isTradingDay(at: mondayEarlyJST))
        XCTAssertFalse(MarketCategory.japan.isTradingDay(at: mondayEarlyJST))
        XCTAssertFalse(MarketCategory.vietnam.isTradingDay(at: mondayEarlyJST))
        XCTAssertTrue(MarketCategory.crypto.isTradingDay(at: mondayEarlyJST))

        // Symbol helper check at Monday 5:37 AM JST
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "GOOG", at: mondayEarlyJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "VOO", at: mondayEarlyJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "7203.T", at: mondayEarlyJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "VNM", at: mondayEarlyJST))
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "BTC-USD", at: mondayEarlyJST))

        // 2. Monday 10:00 AM JST (2026-08-31T10:00:00+09:00)
        // - In Tokyo: Monday 10:00 JST -> JP is ACTIVE (TSE opened at 09:00)
        // - In NY: Sunday 21:00 EDT -> US is CLOSED (Sunday)
        // - In VN: Monday 08:00 ICT -> VN is CLOSED (before 09:00 open)
        let monday10amJST = isoFormatter.date(from: "2026-08-31T10:00:00+09:00")!
        XCTAssertTrue(MarketCategory.japan.isTradingDay(at: monday10amJST))
        XCTAssertFalse(MarketCategory.us.isTradingDay(at: monday10amJST))
        XCTAssertFalse(MarketCategory.vietnam.isTradingDay(at: monday10amJST))
        XCTAssertTrue(MarketCategory.crypto.isTradingDay(at: monday10amJST))

        // 3. Monday 11:30 AM JST (2026-08-31T11:30:00+09:00)
        // - In Tokyo: Monday 11:30 JST -> JP is ACTIVE
        // - In VN: Monday 09:30 ICT -> VN is ACTIVE (opened at 09:00)
        // - In NY: Sunday 22:30 EDT -> US is CLOSED (Sunday)
        let monday1130amJST = isoFormatter.date(from: "2026-08-31T11:30:00+09:00")!
        XCTAssertTrue(MarketCategory.japan.isTradingDay(at: monday1130amJST))
        XCTAssertTrue(MarketCategory.vietnam.isTradingDay(at: monday1130amJST))
        XCTAssertFalse(MarketCategory.us.isTradingDay(at: monday1130amJST))
        XCTAssertTrue(MarketCategory.crypto.isTradingDay(at: monday1130amJST))

        // 4. Monday 11:00 PM JST (2026-08-31T23:00:00+09:00)
        // - In NY: Monday 10:00 AM EDT -> US is ACTIVE
        // - In Tokyo: Monday 23:00 JST -> JP holds Monday's session until Tuesday 09:00 -> ACTIVE
        // - In VN: Monday 21:00 ICT -> VN holds Monday's session until Tuesday 09:00 -> ACTIVE
        let monday11pmJST = isoFormatter.date(from: "2026-08-31T23:00:00+09:00")!
        XCTAssertTrue(MarketCategory.us.isTradingDay(at: monday11pmJST))
        XCTAssertTrue(MarketCategory.japan.isTradingDay(at: monday11pmJST))
        XCTAssertTrue(MarketCategory.vietnam.isTradingDay(at: monday11pmJST))
        XCTAssertTrue(MarketCategory.crypto.isTradingDay(at: monday11pmJST))

        // 5. Saturday 10:00 AM JST (2026-08-29T10:00:00+09:00)
        // - In NY: Friday 21:00 EDT -> US holds Friday's session -> ACTIVE
        // - In Tokyo: Saturday 10:00 JST -> JP is CLOSED (Saturday)
        // - In VN: Saturday 08:00 ICT -> VN is CLOSED (Saturday)
        let saturday10amJST = isoFormatter.date(from: "2026-08-29T10:00:00+09:00")!
        XCTAssertTrue(MarketCategory.us.isTradingDay(at: saturday10amJST))
        XCTAssertFalse(MarketCategory.japan.isTradingDay(at: saturday10amJST))
        XCTAssertFalse(MarketCategory.vietnam.isTradingDay(at: saturday10amJST))
        XCTAssertTrue(MarketCategory.crypto.isTradingDay(at: saturday10amJST))

        // 6. Sunday 12:00 PM JST (2026-08-30T12:00:00+09:00)
        // - All stock markets closed, Crypto active
        let sundayNoonJST = isoFormatter.date(from: "2026-08-30T12:00:00+09:00")!
        XCTAssertFalse(MarketCategory.us.isTradingDay(at: sundayNoonJST))
        XCTAssertFalse(MarketCategory.japan.isTradingDay(at: sundayNoonJST))
        XCTAssertFalse(MarketCategory.vietnam.isTradingDay(at: sundayNoonJST))
        XCTAssertTrue(MarketCategory.crypto.isTradingDay(at: sundayNoonJST))
    }
}
