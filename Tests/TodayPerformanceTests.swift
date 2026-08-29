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
        // Calendar with known Sunday (2026-08-30) and Monday (2026-08-31)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let saturday = formatter.date(from: "2026-08-29")!
        let sunday = formatter.date(from: "2026-08-30")!
        let monday = formatter.date(from: "2026-08-31")!

        // Crypto is always trading
        XCTAssertTrue(MarketCategory.crypto.isTradingDay(at: saturday, calendar: cal))
        XCTAssertTrue(MarketCategory.crypto.isTradingDay(at: sunday, calendar: cal))
        XCTAssertTrue(MarketCategory.crypto.isTradingDay(at: monday, calendar: cal))

        // Stocks are closed on Saturday & Sunday
        XCTAssertFalse(MarketCategory.us.isTradingDay(at: saturday, calendar: cal))
        XCTAssertFalse(MarketCategory.us.isTradingDay(at: sunday, calendar: cal))
        XCTAssertTrue(MarketCategory.us.isTradingDay(at: monday, calendar: cal))

        XCTAssertFalse(MarketCategory.japan.isTradingDay(at: saturday, calendar: cal))
        XCTAssertFalse(MarketCategory.japan.isTradingDay(at: sunday, calendar: cal))
        XCTAssertTrue(MarketCategory.japan.isTradingDay(at: monday, calendar: cal))

        XCTAssertFalse(MarketCategory.vietnam.isTradingDay(at: saturday, calendar: cal))
        XCTAssertFalse(MarketCategory.vietnam.isTradingDay(at: sunday, calendar: cal))
        XCTAssertTrue(MarketCategory.vietnam.isTradingDay(at: monday, calendar: cal))

        // Helper on symbols
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "AAPL", at: saturday, calendar: cal))
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "BTC-USD", at: saturday, calendar: cal))
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "ETHUSDT", at: sunday, calendar: cal))
    }
}
