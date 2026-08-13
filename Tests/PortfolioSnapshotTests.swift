import XCTest
@testable import StockDeck

/// Covers the historical-snapshot foundation for the Portfolio window:
/// (1) portfolio valuation aggregation (value + cost in the preferred currency,
/// reusing the signed/leverage-aware `Holding` math), and (2) the one-per-day
/// snapshot log (append a new day, replace the same day so the latest intraday
/// value wins). The log accumulates forward — there is no historical backfill.
final class PortfolioSnapshotTests: XCTestCase {

    private func input(qty: Double, avg: Double, price: Double, rate: Double = 1, costRate: Double = 1, leverage: Double? = nil) -> PortfolioValuation.Input {
        PortfolioValuation.Input(
            holding: Holding(symbol: "X", quantity: qty, avgPrice: avg, leverage: leverage),
            price: price, rate: rate, costRate: costRate
        )
    }

    // MARK: - Valuation

    func testTotalsAggregatesLongPositions() {
        let totals = PortfolioValuation.totals([
            input(qty: 10, avg: 100, price: 120), // value 1200, cost 1000
            input(qty: 5,  avg: 50,  price: 60),  // value 300,  cost 250
        ])
        XCTAssertEqual(totals.value, 1500, accuracy: 1e-9)
        XCTAssertEqual(totals.cost, 1250, accuracy: 1e-9)
    }

    func testTotalsAppliesExchangeRates() {
        // A USD holding valued in EUR: current rate 0.90, purchase-date rate 0.85.
        let totals = PortfolioValuation.totals([
            input(qty: 10, avg: 100, price: 120, rate: 0.90, costRate: 0.85)
        ])
        XCTAssertEqual(totals.value, 1200 * 0.90, accuracy: 1e-9)
        XCTAssertEqual(totals.cost, 1000 * 0.85, accuracy: 1e-9)
    }

    func testTotalsRespectsShortAndLeverage() {
        // Short 10 @ 100, price 80, 2× leverage → market value = 80*-10*2 = -1600,
        // cost basis = 100*-10*2 = -2000. P&L (value-cost) = +400 (short profit).
        let totals = PortfolioValuation.totals([
            input(qty: -10, avg: 100, price: 80, leverage: 2)
        ])
        XCTAssertEqual(totals.value, -1600, accuracy: 1e-9)
        XCTAssertEqual(totals.cost, -2000, accuracy: 1e-9)
        let snap = PortfolioSnapshot(date: Date(timeIntervalSince1970: 0), totalValue: totals.value, totalCost: totals.cost)
        XCTAssertEqual(snap.totalPnl, 400, accuracy: 1e-9)
    }

    func testEmptyPortfolioIsZero() {
        let totals = PortfolioValuation.totals([])
        XCTAssertEqual(totals.value, 0)
        XCTAssertEqual(totals.cost, 0)
        XCTAssertEqual(totals.pnl, 0)
    }

    /// Binance balances without order history have avgPrice = .nan (no cost
    /// basis). They still have a real market value, but their P&L is unknown and
    /// must be 0 — never the entire market value reported as profit.
    func testNoCostBasisContributesValueButZeroPnl() {
        let missingCost = Holding(symbol: "BTC-USD", quantity: 1, avgPrice: .nan)
        let totals = PortfolioValuation.totals([
            PortfolioValuation.Input(holding: missingCost, price: 87000, rate: 1, costRate: 1)
        ])
        XCTAssertEqual(totals.value, 87000, accuracy: 1e-9)
        XCTAssertEqual(totals.cost, 0, accuracy: 1e-9)
        XCTAssertEqual(totals.pnl, 0, accuracy: 1e-9)
    }

    /// A symbol with mixed lots — one with a known cost basis and one synced
    /// without an order history (avgPrice = .nan) — has an unknowable cost for
    /// the symbol as a whole. Its cost and P&L must be excluded entirely so the
    /// total never counts the partially-known lot's profit; only the real market
    /// value counts (regression for the menu-bar Total P&L).
    func testMixedCostBasisExcludesWholeSymbolCostAndPnl() {
        let withCost = Holding(symbol: "BTC-USD", quantity: 0.02, avgPrice: 64000)
        let missingCost = Holding(symbol: "BTC-USD", quantity: 0.11, avgPrice: .nan)
        let totals = PortfolioValuation.totals([
            PortfolioValuation.Input(holding: withCost, price: 87000, rate: 1, costRate: 1),
            PortfolioValuation.Input(holding: missingCost, price: 87000, rate: 1, costRate: 1),
        ])
        // Value counts both lots (real market value); cost and P&L are unknown.
        XCTAssertEqual(totals.value, 87000 * 0.13, accuracy: 1e-9)
        XCTAssertEqual(totals.cost, 0, accuracy: 1e-9)
        XCTAssertEqual(totals.pnl, 0, accuracy: 1e-9)
    }

    /// Distinct symbols keep independent all-or-nothing gating: a symbol with a
    /// complete cost basis still contributes normally even when another symbol
    /// in the same portfolio is missing its basis.
    func testMixedCostBasisAffectsOnlySymbolWithMissingLots() {
        let complete = PortfolioValuation.Input(holding: Holding(symbol: "META", quantity: 2, avgPrice: 604.075), price: 700, rate: 1, costRate: 1)
        let broken = PortfolioValuation.Input(holding: Holding(symbol: "ETH-USD", quantity: 2.046, avgPrice: .nan), price: 3500, rate: 1, costRate: 1)
        let totals = PortfolioValuation.totals([complete, broken])
        XCTAssertEqual(totals.value, 700 * 2 + 3500 * 2.046, accuracy: 1e-9)
        XCTAssertEqual(totals.cost, 604.075 * 2, accuracy: 1e-9)
        XCTAssertEqual(totals.pnl, (700 - 604.075) * 2, accuracy: 1e-9)
    }

    // MARK: - Native totals (shared per-symbol all-or-nothing rule)

    /// A homogeneous lot group contributes full value, cost, and P&L in the
    /// stock's native currency.
    func testNativeTotalsCompleteCostBasis() {
        let holdings = [
            Holding(symbol: "AAPL", quantity: 2, avgPrice: 150),
            Holding(symbol: "AAPL", quantity: 3, avgPrice: 160),
        ]
        let t = PortfolioValuation.nativeTotals(holdings: holdings, currentPrice: 200)
        XCTAssertEqual(t.value, 200 * 5, accuracy: 1e-9)
        XCTAssertEqual(t.cost, 150 * 2 + 160 * 3, accuracy: 1e-9)
        let expectedPnl = (200.0 * 5.0) - (150.0 * 2.0 + 160.0 * 3.0)
        XCTAssertEqual(t.pnl, expectedPnl, accuracy: 1e-9)
    }

    /// Regression for the grouped holding row in the sidebar: a symbol with
    /// mixed lots (one known, one NaN) must show 0 cost and 0 P&L, never the
    /// partially-known lot's profit — exactly like the menu bar total.
    func testNativeTotalsMixedCostBasisExcludesSymbolPnl() {
        let holdings = [
            Holding(symbol: "BTC-USD", quantity: 0.02115334, avgPrice: 64692.880018),
            Holding(symbol: "BTC-USD", quantity: 0.11058345, avgPrice: .nan),
        ]
        let t = PortfolioValuation.nativeTotals(holdings: holdings, currentPrice: 60000)
        // Market value is real and kept.
        XCTAssertEqual(t.value, 60000 * 0.13173679, accuracy: 1e-6)
        // Cost & P&L are unknowable for the symbol as a whole.
        XCTAssertEqual(t.cost, 0, accuracy: 1e-9)
        XCTAssertEqual(t.pnl, 0, accuracy: 1e-9)
    }

    /// A single fully-unknown holding (e.g. a Binance balance without order
    /// history) keeps its value but contributes 0 cost and P&L.
    func testNativeTotalsMissingCostBasisKeepsValue() {
        let holdings = [Holding(symbol: "SOL-USD", quantity: 8.67125312, avgPrice: .nan)]
        let t = PortfolioValuation.nativeTotals(holdings: holdings, currentPrice: 120)
        XCTAssertEqual(t.value, 120 * 8.67125312, accuracy: 1e-6)
        XCTAssertEqual(t.cost, 0, accuracy: 1e-9)
        XCTAssertEqual(t.pnl, 0, accuracy: 1e-9)
    }

    /// Leverage is respected: value, cost, and P&L all scale with the effective
    /// multiplier, and the all-or-nothing gate still applies.
    func testNativeTotalsRespectsLeverage() {
        let holdings = [
            Holding(symbol: "AAPL", quantity: 10, avgPrice: 100, leverage: 2),
            Holding(symbol: "AAPL", quantity: 1, avgPrice: 150, leverage: 1),
        ]
        let t = PortfolioValuation.nativeTotals(holdings: holdings, currentPrice: 120)
        XCTAssertEqual(t.value, 120 * 10 * 2 + 120 * 1, accuracy: 1e-9)
        XCTAssertEqual(t.cost, 100 * 10 * 2 + 150 * 1, accuracy: 1e-9)
        let expectedPnl = (120.0 * 10.0 * 2.0 - 100.0 * 10.0 * 2.0) + (120.0 - 150.0) * 1.0
        XCTAssertEqual(t.pnl, expectedPnl, accuracy: 1e-9)
    }

    /// The Japanese mutual fund 10,000 scale flows through Holding's accessors:
    /// a 100-quantity fund at 10,000 口-level prices is a small real value.
    func testNativeTotalsScalesJapaneseFund() {
        let h = Holding(symbol: "9I31223A", quantity: 74025, avgPrice: 13509)
        let t = PortfolioValuation.nativeTotals(holdings: [h], currentPrice: 14000)
        XCTAssertEqual(t.value, (14000 / 10000) * 74025, accuracy: 1e-9)
        XCTAssertEqual(t.cost, (13509 / 10000) * 74025, accuracy: 1e-9)
        XCTAssertEqual(t.pnl, ((14000 - 13509) / 10000) * 74025, accuracy: 1e-9)
    }

    // MARK: - Snapshot derived metrics

    func testPnlPercentUsesMagnitudeOfCost() {
        let snap = PortfolioSnapshot(date: Date(), totalValue: 1250, totalCost: 1000)
        XCTAssertEqual(snap.totalPnl, 250, accuracy: 1e-9)
        XCTAssertEqual(snap.pnlPercent, 25, accuracy: 1e-9)
    }

    func testPnlPercentIsZeroWhenCostNegligible() {
        let snap = PortfolioSnapshot(date: Date(), totalValue: 500, totalCost: 0)
        XCTAssertEqual(snap.pnlPercent, 0)
    }

    // MARK: - One-per-day log

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testUpsertAppendsNewDay() {
        var log: [PortfolioSnapshot] = []
        log = SnapshotLog.upsert(PortfolioSnapshot(date: day(2026, 7, 14), totalValue: 100, totalCost: 90), into: log)
        log = SnapshotLog.upsert(PortfolioSnapshot(date: day(2026, 7, 15), totalValue: 110, totalCost: 90), into: log)
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log.map(\.totalValue), [100, 110]) // chronological
    }

    func testUpsertReplacesSameDayWithLatestValue() {
        var log: [PortfolioSnapshot] = []
        // Morning value, then an afternoon refresh the same day.
        log = SnapshotLog.upsert(PortfolioSnapshot(date: day(2026, 7, 15), totalValue: 100, totalCost: 90), into: log)
        log = SnapshotLog.upsert(PortfolioSnapshot(date: day(2026, 7, 15), totalValue: 137, totalCost: 90), into: log)
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].totalValue, 137, accuracy: 1e-9)
    }

    func testUpsertKeepsChronologicalOrderWhenBackfilling() {
        var log: [PortfolioSnapshot] = []
        log = SnapshotLog.upsert(PortfolioSnapshot(date: day(2026, 7, 15), totalValue: 110, totalCost: 90), into: log)
        // An out-of-order insert (e.g. clock skew) still sorts correctly.
        log = SnapshotLog.upsert(PortfolioSnapshot(date: day(2026, 7, 14), totalValue: 100, totalCost: 90), into: log)
        XCTAssertEqual(log.map(\.totalValue), [100, 110])
    }

    func testIsNewDay() {
        let log = [PortfolioSnapshot(date: day(2026, 7, 15), totalValue: 100, totalCost: 90)]
        XCTAssertFalse(SnapshotLog.isNewDay(day(2026, 7, 15), in: log))
        XCTAssertTrue(SnapshotLog.isNewDay(day(2026, 7, 16), in: log))
    }
}
