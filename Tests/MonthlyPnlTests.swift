import XCTest
@testable import StockDeck

/// Covers the monthly P&L table built from real cost basis × price history.
/// Verifies that adding cash / positions never fabricates profit — the core
/// promise of the feature (snapshot-based charts would be inflated instead).
final class MonthlyPnlTests: XCTestCase {

    private func holding(symbol: String = "X", qty: Double, avg: Double, purchased: Date? = nil) -> Holding {
        Holding(symbol: symbol, quantity: qty, avgPrice: avg, purchaseDate: purchased)
    }

    private func month(_ year: Int, _ month: Int) -> Date {
        let cal = Calendar.current
        return cal.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    private func history(prices: [(year: Int, month: Int, close: Double)], symbol: String = "X") -> [String: [PricePoint]] {
        let cal = Calendar.current
        let points = prices.map { p in
            let date = cal.date(from: DateComponents(year: p.year, month: p.month, day: 28))!
            return PricePoint(date: date, close: p.close)
        }
        return [symbol: points]
    }

    private func rows(_ h: [Holding], _ hist: [String: [PricePoint]], today: Date) -> [MonthlyPnlRow] {
        let rates = Dictionary(uniqueKeysWithValues: h.map { ($0.symbol, 1.0) })
        return MonthlyPnl.rows(holdings: h, historyBySymbol: hist, rateBySymbol: rates, today: today, monthCount: 3)
    }

    // MARK: - Single long position

    func testMonthPnlIsPriceMoveTimesQuantity() {
        // Bought at 100. Prices: Apr 100, May 110, Jun 115 (current month Jun).
        let h = [holding(qty: 10, avg: 100)]
        let hist = history(prices: [(2026, 4, 100), (2026, 5, 110), (2026, 6, 115)])
        let today = month(2026, 6)
        let r = rows(h, hist, today: today)

        XCTAssertEqual(r.count, 3)
        // Newest first: Jun, May, Apr.
        XCTAssertEqual(r[0].label, "Jun 2026")
        // Jun cumulative P&L = (115-100)*10 = 150; May cumulative = (110-100)*10 = 100.
        // Jun own P&L = 150-100 = 50 (the +5 move). May own = 100 (diff vs Apr 0).
        XCTAssertEqual(r[0].pnl ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(r[1].pnl ?? 0, 100, accuracy: 1e-9)
        // Oldest month shows its cumulative P&L (no prior month to diff).
        XCTAssertEqual(r[2].pnl ?? 0, 0, accuracy: 1e-9)
    }

    func testMonthPnlPercentIsRelativeToStartOfMonthValue() {
        let h = [holding(qty: 10, avg: 100)]
        let hist = history(prices: [(2026, 4, 100), (2026, 5, 110), (2026, 6, 115)])
        let r = rows(h, hist, today: month(2026, 6))

        // Jun: +50 on a start-of-month value of 110*10 = 1100 → 4.545%.
        XCTAssertEqual(r[0].pnlPercent ?? 0, 50.0 / 1100.0 * 100, accuracy: 1e-9)
    }

    func testAddingNewPositionDoesNotFabricatePnl() {
        // Two holdings: existing at 100, and a NEW lot bought in Jun at 115 (≈ current price).
        let old = holding(symbol: "X", qty: 10, avg: 100)
        let new = holding(symbol: "Y", qty: 5, avg: 115)
        let cal = Calendar.current
        let hist = [
            "X": [
                PricePoint(date: cal.date(from: DateComponents(year: 2026, month: 5, day: 28))!, close: 110),
                PricePoint(date: cal.date(from: DateComponents(year: 2026, month: 6, day: 28))!, close: 115)
            ],
            "Y": [
                PricePoint(date: cal.date(from: DateComponents(year: 2026, month: 6, day: 28))!, close: 115)
            ]
        ]
        let rates = ["X": 1.0, "Y": 1.0]
        let r = MonthlyPnl.rows(holdings: [old, new], historyBySymbol: hist, rateBySymbol: rates, today: month(2026, 6), monthCount: 2)

        // New lot bought at 115, price still 115 → contributes 0 P&L. Jun own P&L
        // comes only from X's +5 move: (115-100)*10 - (110-100)*10 = 50.
        XCTAssertEqual(r[0].pnl ?? 0, 50, accuracy: 1e-9)
    }

    func testPurchaseDateAfterMonthExcludesHoldingFromThatMonth() {
        // Bought only in Jun, so May shows no P&L for it.
        let h = [holding(qty: 10, avg: 100, purchased: month(2026, 6))]
        let hist = history(prices: [(2026, 5, 100), (2026, 6, 115)])
        let r = rows(h, hist, today: month(2026, 6))

        // Jun: bought at 100, price 115 → (115-100)*10 = 150.
        XCTAssertEqual(r[0].pnl ?? 0, 150, accuracy: 1e-9)
        // May: holding did not exist → cumulative P&L 0.
        XCTAssertEqual(r[1].pnl ?? 0, 0, accuracy: 1e-9)
    }

    func testShortPositionPnlSign() {
        // Short 10 @ 100; price drops to 90 → profit +100 in that month.
        let h = [holding(qty: -10, avg: 100)]
        let hist = history(prices: [(2026, 5, 100), (2026, 6, 90)])
        let r = rows(h, hist, today: month(2026, 6))
        XCTAssertEqual(r[0].pnl ?? 0, 100, accuracy: 1e-9)
    }

    func testLeverageMultipliesMonthPnl() {
        let h = [holding(qty: 10, avg: 100, purchased: month(2026, 5))]
        let l = Holding(symbol: "X", quantity: 10, avgPrice: 100, leverage: 3)
        let hist = history(prices: [(2026, 5, 100), (2026, 6, 110)])
        let rates = ["X": 1.0]
        let r = MonthlyPnl.rows(holdings: [l], historyBySymbol: hist, rateBySymbol: rates, today: month(2026, 6), monthCount: 2)
        XCTAssertEqual(r[0].pnl ?? 0, 300, accuracy: 1e-9)
    }

    // MARK: - Japanese funds

    func testJapaneseFundScaleApplied() {
        // NAV per 10,000 口: bought at 10,000, price 11,000 → per-口 gain 0.1 × qty.
        let h = [holding(symbol: "9I31223A", qty: 10_000, avg: 10_000)]
        let hist = history(prices: [(2026, 5, 10_000), (2026, 6, 11_000)], symbol: "9I31223A")
        let r = rows(h, hist, today: month(2026, 6))
        XCTAssertEqual(r[0].pnl ?? 0, 1000, accuracy: 1e-9)
    }

    func testMissingHistoryShowsNilNotFabricated() {
        let h = [holding(qty: 10, avg: 100)]
        let hist = history(prices: [(2026, 6, 115)]) // no May data
        let r = rows(h, hist, today: month(2026, 6))
        // May carries no data → trimmed; only Jun remains as the oldest month,
        // showing its cumulative P&L (150) with no percent.
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].pnl ?? 0, 150, accuracy: 1e-9)
        XCTAssertNil(r[0].pnlPercent)
    }

    func testOldestMonthsWithoutDataAreTrimmed() {
        // Data only exists for Apr→Jun; Mar and earlier (in a wider window) must
        // not appear as zero bars at the start of the chart.
        let h = [holding(qty: 10, avg: 100)]
        let hist = history(prices: [(2026, 4, 100), (2026, 5, 110), (2026, 6, 115)])
        let rates = ["X": 1.0]
        let r = MonthlyPnl.rows(holdings: h, historyBySymbol: hist, rateBySymbol: rates,
                                today: month(2026, 6), monthCount: 5)
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r[0].label, "Jun 2026")
        XCTAssertEqual(r[2].label, "Apr 2026")
    }

    func testFXRateApplied() {
        let h = [holding(qty: 10, avg: 100)]
        let hist = history(prices: [(2026, 5, 100), (2026, 6, 110)])
        let rates = ["X": 2.0]
        let r = MonthlyPnl.rows(holdings: h, historyBySymbol: hist, rateBySymbol: rates, today: month(2026, 6), monthCount: 2)
        // Jun own P&L = ((110-100)/1 * 10 * 1 * 2) - 0 = 200.
        XCTAssertEqual(r[0].pnl ?? 0, 200, accuracy: 1e-9)
    }

    func testEmptyHoldingsReturnsEmpty() {
        let r = MonthlyPnl.rows(holdings: [], historyBySymbol: [:], rateBySymbol: [:], today: Date())
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: - Month count (dynamic window)

    func testMonthCountUsesEarliestHistoryDate() {
        // Data starts 24 months ago → 25 months of bars (capped at 36).
        let points = [PricePoint(date: month(2024, 8), close: 100)]
        let m = MonthlyPnl.monthCount(for: ["X": points], today: month(2026, 8), maxMonths: 36)
        XCTAssertEqual(m, 25)
    }

    func testMonthCountCappedAtMax() {
        let points = [PricePoint(date: month(2020, 1), close: 100)]
        let m = MonthlyPnl.monthCount(for: ["X": points], today: month(2026, 8), maxMonths: 36)
        XCTAssertEqual(m, 36)
    }

    func testMonthCountFallsBackToDefaultWhenNoData() {
        XCTAssertEqual(MonthlyPnl.monthCount(for: [:], today: month(2026, 8)), 12)
    }

    func testMonthCountReturnsAvailableWhenBelowDefault() {
        // Only 3 months of data → 4 bars, not a padded 12.
        let points = [PricePoint(date: month(2026, 5), close: 100)]
        let m = MonthlyPnl.monthCount(for: ["X": points], today: month(2026, 8), maxMonths: 36)
        XCTAssertEqual(m, 4)
    }
}
