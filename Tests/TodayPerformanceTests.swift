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

        // Symbol helper check at Monday 5:37 AM JST (Sun 16:37 EDT) -> CME futures NOT yet open (opens 18:00 EDT)
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "GOOG", at: mondayEarlyJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "VOO", at: mondayEarlyJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "7203.T", at: mondayEarlyJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "VNM", at: mondayEarlyJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "ES=F", at: mondayEarlyJST))
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "BTC-USD", at: mondayEarlyJST))

        // 2. Monday 10:00 AM JST (2026-08-31T10:00:00+09:00)
        // - In Tokyo: Monday 10:00 JST -> JP is ACTIVE (TSE opened at 09:00)
        // - In NY: Sunday 21:00 EDT -> US stock is CLOSED, but CME Globex Futures ARE ACTIVE (opened at 18:00 EDT)
        // - In VN: Monday 08:00 ICT -> VN is CLOSED (before 09:00 open)
        let monday10amJST = isoFormatter.date(from: "2026-08-31T10:00:00+09:00")!
        XCTAssertTrue(MarketCategory.japan.isTradingDay(at: monday10amJST))
        XCTAssertFalse(MarketCategory.us.isTradingDay(at: monday10amJST))
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "ES=F", at: monday10amJST))
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "NQ=F", at: monday10amJST))

        // Live quote at active time
        let liveRegularQuote = StockQuote(symbol: "ES=F", name: "E-mini S&P 500", price: 7743, change: 30.5, changePercent: 0.4, currency: "USD", marketState: "REGULAR")
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "ES=F", quote: liveRegularQuote, at: monday10amJST))

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

        // 7. Monday 9:29 AM JST (2026-08-31T09:29:12+09:00)
        // - KOSPI (^KS11, South Korea) opens at 09:00 KST (same as JST) -> ACTIVE
        // - Nikkei 225 (^N225, Japan) opens at 09:00 JST -> ACTIVE
        // - Nifty 50 (^NSEI, India) is 05:59 IST (before 09:15 IST) -> CLOSED
        // - Hang Seng (^HSI, Hong Kong) is 08:29 HKT (before 09:00 HKT) -> CLOSED
        // - FTSE (^FTSE, London) is 01:29 BST (before 08:00 BST) -> CLOSED
        // - S&P 500 (^GSPC, US) is 20:29 EDT Sunday -> CLOSED
        let monday929amJST = isoFormatter.date(from: "2026-08-31T09:29:12+09:00")!
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "^KS11", at: monday929amJST))
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "005930.KS", at: monday929amJST))
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "^N225", at: monday929amJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "^NSEI", at: monday929amJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "^HSI", at: monday929amJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "^FTSE", at: monday929amJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "^GSPC", at: monday929amJST))

        // 8. Monday 1:00 PM JST (2026-08-31T13:00:00+09:00)
        // - India is 09:30 IST (after 09:15 IST open) -> ACTIVE
        // - Hong Kong is 12:00 HKT (after 09:00 HKT open) -> ACTIVE
        let monday1pmJST = isoFormatter.date(from: "2026-08-31T13:00:00+09:00")!
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "^NSEI", at: monday1pmJST))
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "^HSI", at: monday1pmJST))

        // 9. Monday 5:13 PM JST (2026-08-31T17:13:22+09:00)
        // - In NY: Monday 04:13 AM EDT (Pre-market) -> US regular session opens at 09:30 EDT -> CLOSED
        // - In Tokyo: Monday 17:13 JST (Holds Monday regular session) -> ACTIVE
        // - In VN: Monday 15:13 ICT (Holds Monday regular session) -> ACTIVE
        // - Crypto: ACTIVE (24/7)
        let monday513pmJST = isoFormatter.date(from: "2026-08-31T17:13:22+09:00")!
        XCTAssertFalse(MarketCategory.us.isTradingDay(at: monday513pmJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "SPGI", at: monday513pmJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "META", at: monday513pmJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "RACE", at: monday513pmJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "GOOG", at: monday513pmJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "^GSPC", at: monday513pmJST))
        XCTAssertTrue(MarketCategory.japan.isTradingDay(at: monday513pmJST))
        XCTAssertTrue(MarketCategory.vietnam.isTradingDay(at: monday513pmJST))
        XCTAssertTrue(MarketCategory.crypto.isTradingDay(at: monday513pmJST))

        // 10. Monday 10:30 PM JST (2026-08-31T22:30:00+09:00)
        // - In NY: Monday 09:30 AM EDT -> US Regular opening bell -> ACTIVE
        let monday1030pmJST = isoFormatter.date(from: "2026-08-31T22:30:00+09:00")!
        XCTAssertTrue(MarketCategory.us.isTradingDay(at: monday1030pmJST))
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "SPGI", at: monday1030pmJST))
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "META", at: monday1030pmJST))

        // 11. Stale quote with marketState == "REGULAR" cannot override weekend / pre-market calendar
        let mockStaleGoogQuote = StockQuote(symbol: "GOOG", name: "Alphabet", price: 175, marketState: "REGULAR")
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "GOOG", quote: mockStaleGoogQuote, at: sundayNoonJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "GOOG", quote: mockStaleGoogQuote, at: monday929amJST))
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "GOOG", quote: mockStaleGoogQuote, at: monday513pmJST))
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "GOOG", quote: mockStaleGoogQuote, at: monday11pmJST))

        // Crypto quote is always active
        let mockCryptoQuote = StockQuote(symbol: "BTC-USD", name: "Bitcoin", price: 60000, marketState: "CLOSED")
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "BTC-USD", quote: mockCryptoQuote, at: sundayNoonJST))

        // 12. Market holiday during regular session hours (e.g. 2026-09-21 Respect for the Aged Day in Japan)
        // - In Tokyo: Monday 11:00 AM JST (normally regular hours 09:00 - 15:30 JST)
        // - Live provider explicitly marks marketState == "CLOSED" for holiday -> MUST BE CLOSED
        let monday11amJST = isoFormatter.date(from: "2026-09-21T11:00:00+09:00")!
        let closedNikkeiQuote = StockQuote(
            symbol: "^N225",
            name: "Nikkei 225",
            price: 45630,
            marketState: "CLOSED",
            regularMarketTime: isoFormatter.date(from: "2026-09-18T15:30:00+09:00")
        )
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "^N225", quote: closedNikkeiQuote, at: monday11amJST))

        // 13. Active foreign session during regular session hours on the same calendar day (South Korea open)
        // - In Seoul: Monday 11:00 AM KST
        // - Live provider marks marketState == "REGULAR" -> ACTIVE
        let regularSamsungQuote = StockQuote(
            symbol: "005930.KS",
            name: "Samsung Electronics",
            price: 80000,
            marketState: "REGULAR",
            regularMarketTime: isoFormatter.date(from: "2026-09-21T10:46:00+09:00")
        )
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "005930.KS", quote: regularSamsungQuote, at: monday11amJST))

        // 14. After-hours check: Holiday (last trade was prior Friday) vs Active trading day
        let monday6pmJST = isoFormatter.date(from: "2026-09-21T18:00:00+09:00")!
        // A full-day holiday where last regularMarketTime was Friday Sep 18 -> CLOSED
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "^N225", quote: closedNikkeiQuote, at: monday6pmJST))

        // A normal trading day where regularMarketTime was from earlier today Sep 21 at 15:30 JST -> ACTIVE (holds session)
        let activeTradingDayNikkei = StockQuote(
            symbol: "^N225",
            name: "Nikkei 225",
            price: 45630,
            marketState: "CLOSED",
            regularMarketTime: isoFormatter.date(from: "2026-09-21T15:30:00+09:00")
        )
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "^N225", quote: activeTradingDayNikkei, at: monday6pmJST))

        // 15. Vietnam stocks during regular session hours (e.g. Monday 14:16 ICT)
        // Normal active trading day: marketState == "REGULAR" and regularMarketTime from earlier today -> ACTIVE
        let monday216pmICT = isoFormatter.date(from: "2026-09-21T14:16:00+07:00")!
        let activeMBBQuote = StockQuote(
            symbol: "MBB",
            name: "MBBank",
            price: 20000,
            marketState: "REGULAR",
            regularMarketTime: isoFormatter.date(from: "2026-09-21T09:00:00+07:00")
        )
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "MBB", quote: activeMBBQuote, at: monday216pmICT))

        let activeVNIndexQuote = StockQuote(
            symbol: "^VNINDEX.VN",
            name: "VN-Index",
            price: 1791.69,
            marketState: "REGULAR",
            regularMarketTime: isoFormatter.date(from: "2026-09-21T14:15:00+07:00")
        )
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "^VNINDEX.VN", quote: activeVNIndexQuote, at: monday216pmICT))

        // 16. Vietnam special holiday (e.g. National Day Sep 2 / Tet during weekday session hours)
        // Exchange observes full-day holiday: marketState is "CLOSED" and last traded candle was prior date -> MUST BE CLOSED
        let wednesday10amICTHoliday = isoFormatter.date(from: "2026-09-02T10:00:00+07:00")!
        let holidayMBBQuote = StockQuote(
            symbol: "MBB",
            name: "MBBank",
            price: 19800,
            marketState: "CLOSED",
            regularMarketTime: isoFormatter.date(from: "2026-09-01T15:00:00+07:00")
        )
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "MBB", quote: holidayMBBQuote, at: wednesday10amICTHoliday))

        // 17. Vietnam after-hours: Normal trading day vs Special holiday
        let monday6pmICT = isoFormatter.date(from: "2026-09-21T18:00:00+07:00")!
        // Normal trading day after 15:00 ICT -> ACTIVE (holds session close)
        let closedSessionMBB = StockQuote(
            symbol: "MBB",
            name: "MBBank",
            price: 20000,
            marketState: "CLOSED",
            regularMarketTime: isoFormatter.date(from: "2026-09-21T15:00:00+07:00")
        )
        XCTAssertTrue(MarketCategory.isTradingDay(symbol: "MBB", quote: closedSessionMBB, at: monday6pmICT))

        // Special holiday after 15:00 ICT -> CLOSED (no session took place today)
        let holidayEveningMBB = StockQuote(
            symbol: "MBB",
            name: "MBBank",
            price: 19800,
            marketState: "CLOSED",
            regularMarketTime: isoFormatter.date(from: "2026-09-01T15:00:00+07:00")
        )
        XCTAssertFalse(MarketCategory.isTradingDay(symbol: "MBB", quote: holidayEveningMBB, at: monday6pmICT))

        // 18. MarketCategory.isSessionOpen tests (Option A: closed badge behavior)
        // (a) Vietnam stock during trading hours (14:16 ICT) -> session is OPEN (no Closed badge)
        XCTAssertTrue(MarketCategory.isSessionOpen(symbol: "MBB", quote: activeMBBQuote, at: monday216pmICT))
        XCTAssertTrue(MarketCategory.isSessionOpen(symbol: "^VNINDEX.VN", quote: activeVNIndexQuote, at: monday216pmICT))

        // (b) Vietnam stock after trading hours (16:27 ICT / 18:00 ICT) -> session is CLOSED (shows Closed badge)
        let monday427pmICT = isoFormatter.date(from: "2026-09-21T16:27:00+07:00")!
        XCTAssertFalse(MarketCategory.isSessionOpen(symbol: "MBB", quote: closedSessionMBB, at: monday427pmICT))
        XCTAssertFalse(MarketCategory.isSessionOpen(symbol: "MBB", quote: closedSessionMBB, at: monday6pmICT))

        // (c) Vietnam stock during holiday -> session is CLOSED
        XCTAssertFalse(MarketCategory.isSessionOpen(symbol: "MBB", quote: holidayMBBQuote, at: wednesday10amICTHoliday))

        // (d) Crypto is always open 24/7
        XCTAssertTrue(MarketCategory.isSessionOpen(symbol: "BTC-USD", quote: nil, isCrypto: true, at: monday427pmICT))
        XCTAssertTrue(MarketCategory.isSessionOpen(symbol: "BTC-USD", quote: nil, isCrypto: true, at: wednesday10amICTHoliday))
    }
}

