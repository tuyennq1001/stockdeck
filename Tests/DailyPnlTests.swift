import XCTest
@testable import StockDeck

final class DailyPnlTests: XCTestCase {

    private func day(_ year: Int, _ month: Int, _ d: Int) -> Date {
        let cal = Calendar.current
        return cal.date(from: DateComponents(year: year, month: month, day: d))!
    }

    func testDailyPnlPriceMoveTimesQuantity() {
        let h = [Holding(symbol: "AAPL", quantity: 10, avgPrice: 150)]
        let d1 = day(2026, 6, 1)
        let d2 = day(2026, 6, 2)
        let hist = ["AAPL": [
            PricePoint(date: d1, close: 150),
            PricePoint(date: d2, close: 155)
        ]]
        let rates = ["AAPL": 1.0]
        let r = DailyPnl.rows(
            holdings: h,
            historyBySymbol: hist,
            rateBySymbol: rates,
            today: d2,
            dayCount: 2
        )

        XCTAssertEqual(r.count, 2)
        // d2 is index 0 (newest first)
        XCTAssertEqual(r[0].unrealizedPnl ?? 0, 50, accuracy: 1e-9)
        XCTAssertNil(r[0].realizedPnl)
        XCTAssertEqual(r[0].pnl ?? 0, 50, accuracy: 1e-9)
    }

    func testDailyPnlWithClosedTradeOnSellDate() {
        let h = [Holding(symbol: "AAPL", quantity: 10, avgPrice: 150)]
        let d1 = day(2026, 6, 1)
        let d2 = day(2026, 6, 2)
        let hist = ["AAPL": [
            PricePoint(date: d1, close: 150),
            PricePoint(date: d2, close: 155)
        ]]
        let closedTrade = ClosedTrade(
            symbol: "NVDA",
            quantity: 5,
            buyPrice: 100,
            sellPrice: 140,
            buyDate: d1,
            sellDate: d2
        )
        let rates = ["AAPL": 1.0, "NVDA": 1.0]
        let r = DailyPnl.rows(
            holdings: h,
            closedTrades: [closedTrade],
            historyBySymbol: hist,
            rateBySymbol: rates,
            today: d2,
            dayCount: 2
        )

        XCTAssertEqual(r.count, 2)
        // d2: paper move on AAPL = +50; realized on NVDA = (140-100)*5 = +200 -> total = +250
        XCTAssertEqual(r[0].unrealizedPnl ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(r[0].realizedPnl ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(r[0].pnl ?? 0, 250, accuracy: 1e-9)

        // d1: no closed trade on d1
        XCTAssertNil(r[1].realizedPnl)
    }

    func testDailyPnlWithOnlyClosedTrades() {
        let d1 = day(2026, 6, 1)
        let d2 = day(2026, 6, 2)
        let closedTrade = ClosedTrade(
            symbol: "TSLA",
            quantity: 2,
            buyPrice: 200,
            sellPrice: 250,
            buyDate: d1,
            sellDate: d2
        )
        let r = DailyPnl.rows(
            holdings: [],
            closedTrades: [closedTrade],
            historyBySymbol: [:],
            rateBySymbol: ["TSLA": 1.0],
            today: d2,
            dayCount: 2
        )

        XCTAssertFalse(r.isEmpty)
        let todayRow = r[0]
        XCTAssertEqual(todayRow.realizedPnl ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(todayRow.pnl ?? 0, 100, accuracy: 1e-9)
    }

    func testDailyPnlTodayUsesTodaySummaryWhenPriceHistoryHasNoTodayBar() {
        // Simulates 10:00 AM JST when US stocks only have yesterday's 23:30 JST bar
        // and BTC priceHistory is still 6h-cached from yesterday, yet live quotes exist.
        let d1 = day(2026, 11, 12)
        let d2 = day(2026, 11, 13)
        let d3 = day(2026, 11, 14)

        let holdings = [
            Holding(symbol: "AAPL", quantity: 10, avgPrice: 100),
            Holding(symbol: "BTC-USD", quantity: 1, avgPrice: 60000)
        ]
        let hist: [String: [PricePoint]] = [
            "AAPL": [
                PricePoint(date: d1, close: 200),
                PricePoint(date: d2, close: 190)
            ],
            "BTC-USD": [
                PricePoint(date: d1, close: 70000),
                PricePoint(date: d2, close: 65000)
            ]
        ]

        // Live TodayPerformance: AAPL still -10*10 = -100 (US Friday session active),
        // BTC bounced +500 since 00:00 UTC -> net unrealized = +400.
        let todaySummary = TodayPerformance.summary([
            TodayPerformance.Input(
                holding: holdings[0],
                regularPrice: 190,
                previousClose: 200,
                rate: 1.0,
                isMarketActiveToday: true
            ),
            TodayPerformance.Input(
                holding: holdings[1],
                regularPrice: 65500,
                previousClose: 65000,
                rate: 1.0,
                isMarketActiveToday: true
            )
        ])

        let rows = DailyPnl.rows(
            holdings: holdings,
            historyBySymbol: hist,
            rateBySymbol: ["AAPL": 1.0, "BTC-USD": 1.0],
            todaySummary: todaySummary,
            today: d3,
            dayCount: 3
        )

        XCTAssertEqual(rows.count, 3)
        // Today (d3) must NOT drop to 0; it matches TodayPerformance (+400)
        XCTAssertEqual(rows[0].unrealizedPnl ?? 0, 400, accuracy: 1e-9)
        XCTAssertEqual(rows[0].pnl ?? 0, 400, accuracy: 1e-9)
        XCTAssertEqual(rows[0].pnlPercent ?? 0, (400.0 / 67000.0) * 100.0, accuracy: 1e-6)
        // Yesterday (d2) still reflects historical bar delta: (190-200)*10 + (65000-70000)*1 = -5100
        XCTAssertEqual(rows[1].pnl ?? 0, -5100, accuracy: 1e-9)
    }

    func testDailyPnlTodaySummaryCombinesWithTodayRealizedTradesAndEmptyHistory() {
        let d1 = day(2026, 11, 13)
        let d2 = day(2026, 11, 14)
        let h = [Holding(symbol: "BTC-USD", quantity: 2, avgPrice: 50000)]
        let closed = ClosedTrade(
            symbol: "NVDA",
            quantity: 5,
            buyPrice: 100,
            sellPrice: 120,
            buyDate: d1,
            sellDate: d2
        )
        let summary = TodayPerformance.Summary(gain: 300, percent: 0.3, previousCloseValue: 100000)

        let rows = DailyPnl.rows(
            holdings: h,
            closedTrades: [closed],
            historyBySymbol: [:],
            rateBySymbol: ["BTC-USD": 1.0, "NVDA": 1.0],
            todaySummary: summary,
            today: d2,
            dayCount: 5
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].unrealizedPnl ?? 0, 300, accuracy: 1e-9)
        XCTAssertEqual(rows[0].realizedPnl ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(rows[0].pnl ?? 0, 400, accuracy: 1e-9)
        // prevTotalValue = 100000 + closed costBasis (500) = 100500
        XCTAssertEqual(rows[0].pnlPercent ?? 0, (400.0 / 100500.0) * 100.0, accuracy: 1e-6)
    }

    func testUpdatingTodayRowPatchesOnlyTodayInPlace() {
        let d1 = day(2026, 11, 13)
        let d2 = day(2026, 11, 14)
        let h = [Holding(symbol: "AAPL", quantity: 10, avgPrice: 100)]
        let hist = ["AAPL": [
            PricePoint(date: d1, close: 150)
        ]]

        let initial = DailyPnl.rows(
            holdings: h,
            historyBySymbol: hist,
            rateBySymbol: ["AAPL": 1.0],
            todaySummary: TodayPerformance.Summary(gain: -50, percent: -3.2, previousCloseValue: 1550),
            today: d2,
            dayCount: 2
        )
        XCTAssertEqual(initial.count, 2)
        XCTAssertEqual(initial[0].pnl ?? 0, -50, accuracy: 1e-9)

        let updated = DailyPnl.updatingTodayRow(
            in: initial,
            with: TodayPerformance.Summary(gain: 75, percent: 4.8, previousCloseValue: 1550),
            today: d2
        )
        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(updated[0].pnl ?? 0, 75, accuracy: 1e-9)
        XCTAssertEqual(updated[1], initial[1])
    }
}
