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
}
