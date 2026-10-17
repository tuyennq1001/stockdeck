import XCTest
@testable import StockDeck

/// Covers the hero-pill period change: the delta between the first and last
/// points of the drawn value curve, so the pill reflects the selected range
/// (24H/7D/1M/1Y/All) rather than always the day-over-day move.
final class PortfolioPeriodChangeTests: XCTestCase {

    private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d * 86400)) }
    private func pt(_ d: Int, _ v: Double) -> ValuePoint { ValuePoint(date: day(d), value: v) }

    func testPercentOverSpan() {
        let points = [pt(1, 100), pt(2, 110), pt(3, 120)]
        XCTAssertEqual(PortfolioPeriodChange.percent(points) ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(PortfolioPeriodChange.value(points) ?? 0, 20, accuracy: 1e-9)
    }

    func testNegativeSpan() {
        let points = [pt(1, 200), pt(2, 150)]
        XCTAssertEqual(PortfolioPeriodChange.percent(points) ?? 0, -25, accuracy: 1e-9)
        XCTAssertEqual(PortfolioPeriodChange.value(points) ?? 0, -50, accuracy: 1e-9)
    }

    /// Different windows over the same curve must yield different figures — the
    /// bug was that the pill never changed with the range.
    func testDifferentWindowsDiffer() {
        let full = [pt(1, 100), pt(2, 105), pt(3, 90), pt(4, 108)]
        let lastTwo = Array(full.suffix(2))
        XCTAssertNotEqual(PortfolioPeriodChange.percent(full),
                          PortfolioPeriodChange.percent(lastTwo))
    }

    func testTooFewPointsIsNil() {
        XCTAssertNil(PortfolioPeriodChange.percent([pt(1, 100)]))
        XCTAssertNil(PortfolioPeriodChange.percent([]))
        XCTAssertNil(PortfolioPeriodChange.value([pt(1, 100)]))
    }

    func testDegenerateBaseIsNil() {
        // First point ~0 → percent undefined, but absolute value still defined.
        let points = [pt(1, 0), pt(2, 50)]
        XCTAssertNil(PortfolioPeriodChange.percent(points))
        XCTAssertEqual(PortfolioPeriodChange.value(points) ?? -1, 50, accuracy: 1e-9)
    }

    func testCAGRCalculation() {
        // 100 to 144 over 2 years (730 days) -> CAGR = sqrt(1.44) - 1 = 20%
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 730.5 * 86400)
        let pts = [ValuePoint(date: start, value: 100), ValuePoint(date: end, value: 144)]

        let cagr = PortfolioPeriodChange.cagr(pts)
        XCTAssertNotNil(cagr)
        XCTAssertEqual(cagr ?? 0, 20.0, accuracy: 0.1)

        // Short period (< 350 days) should return nil
        let shortEnd = Date(timeIntervalSince1970: 100 * 86400)
        let shortPts = [ValuePoint(date: start, value: 100), ValuePoint(date: shortEnd, value: 120)]
        XCTAssertNil(PortfolioPeriodChange.cagr(shortPts))
    }

    @MainActor
    func testPortfolioPerformanceAccurateHoldingsValuation() {
        let stockService = StockService.shared
        let now = Date()
        let cal = Calendar.current
        let jan1 = cal.date(from: cal.dateComponents([.year], from: now)) ?? now

        let dec31 = jan1.addingTimeInterval(-86400)
        let today = now

        // Symbol A: gained +20% (100 -> 120)
        stockService.priceHistory["TEST_A"] = [
            PricePoint(date: dec31, close: 100),
            PricePoint(date: today, close: 120)
        ]
        stockService.quotes["TEST_A"] = StockQuote(
            symbol: "TEST_A", name: "Stock A", price: 120, change: 0,
            changePercent: 0, regularMarketPreviousClose: 120,
            currency: "USD"
        )

        // Symbol B: gained +10% (200 -> 220)
        stockService.priceHistory["TEST_B"] = [
            PricePoint(date: dec31, close: 200),
            PricePoint(date: today, close: 220)
        ]
        stockService.quotes["TEST_B"] = StockQuote(
            symbol: "TEST_B", name: "Stock B", price: 220, change: 0,
            changePercent: 0, regularMarketPreviousClose: 220,
            currency: "USD"
        )

        let holdings = [
            Holding(symbol: "TEST_A", quantity: 10, avgPrice: 100), // Cutoff Val: 1000, Cur: 1200
            Holding(symbol: "TEST_B", quantity: 5, avgPrice: 200)   // Cutoff Val: 1000, Cur: 1100
        ]
        // Total Cutoff = 2000, Total Current = 2300 -> +15%
        let perf = PortfolioViewModel.portfolioPerformance(
            for: .ytd, holdings: holdings, stockService: stockService, inception: nil
        )

        XCTAssertNotNil(perf)
        XCTAssertEqual(perf ?? 0, 15.0, accuracy: 1e-4)
    }

    @MainActor
    func testPortfolioPerformanceWithUndatedHoldingsDoesNotBlockYTD() {
        let stockService = StockService.shared
        let now = Date()
        let cal = Calendar.current
        let jan1 = cal.date(from: cal.dateComponents([.year], from: now)) ?? now
        let dec31 = jan1.addingTimeInterval(-86400)

        stockService.priceHistory["TEST_BTC"] = [
            PricePoint(date: dec31, close: 80000),
            PricePoint(date: now, close: 88000)
        ]
        stockService.quotes["TEST_BTC"] = StockQuote(
            symbol: "TEST_BTC", name: "Bitcoin", price: 88000, change: 0,
            changePercent: 0, regularMarketPreviousClose: 88000,
            currency: "USD"
        )

        // Undated holding (synced balance)
        let holdings = [
            Holding(symbol: "TEST_BTC", quantity: 0.1, avgPrice: .nan, purchaseDate: nil)
        ]
        // Even if inception is passed as a recent date, undated holdings allow YTD evaluation
        let recentDate = now.addingTimeInterval(-30 * 86400)
        let perf = PortfolioViewModel.portfolioPerformance(
            for: .ytd, holdings: holdings, stockService: stockService, inception: recentDate
        )

        XCTAssertNotNil(perf)
        XCTAssertEqual(perf ?? 0, 10.0, accuracy: 1e-4)
    }

    @MainActor
    private func createTestStorage() -> (StorageService, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("StockDeckTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("data.json")
        return (StorageService(fileURL: fileURL), tempDir)
    }

    @MainActor
    func testIsRangeAvailableWhenPortfolioIsYoungerThan3YAnd5Y() {
        let (storage, tempDir) = createTestStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pId = UUID()
        let portfolio = Portfolio(id: pId, name: "Test Young Portfolio", holdings: [])
        storage.portfolios = [portfolio]

        let now = Date()
        let cal = Calendar.current
        // Earliest purchase date is 2.5 years ago
        let inceptionDate = cal.date(byAdding: .month, value: -30, to: now)!
        storage.addHolding(to: pId, symbol: "AAPL", quantity: 10, avgPrice: 150, purchaseDate: inceptionDate)

        let vm = PortfolioViewModel(scope: .portfolio(pId))
        vm.setup(stockService: StockService.shared, storageService: storage)

        XCTAssertTrue(vm.isRangeAvailable(.month, now: now, calendar: cal))
        XCTAssertTrue(vm.isRangeAvailable(.threeMonths, now: now, calendar: cal))
        XCTAssertTrue(vm.isRangeAvailable(.sixMonths, now: now, calendar: cal))
        XCTAssertTrue(vm.isRangeAvailable(.ytd, now: now, calendar: cal))
        XCTAssertTrue(vm.isRangeAvailable(.year, now: now, calendar: cal))
        // 3Y, 5Y, 7Y, 10Y must be dimmed / false because portfolio is only 2.5 years old
        XCTAssertFalse(vm.isRangeAvailable(.threeYears, now: now, calendar: cal))
        XCTAssertFalse(vm.isRangeAvailable(.fiveYears, now: now, calendar: cal))
        XCTAssertFalse(vm.isRangeAvailable(.sevenYears, now: now, calendar: cal))
        XCTAssertFalse(vm.isRangeAvailable(.tenYears, now: now, calendar: cal))
        XCTAssertTrue(vm.isRangeAvailable(.all, now: now, calendar: cal))

        // Clean up
        storage.deletePortfolio(id: pId)
    }

    @MainActor
    func testIsRangeAvailableWhenPortfolioIsOlderThan5Y() {
        let (storage, tempDir) = createTestStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pId = UUID()
        let portfolio = Portfolio(id: pId, name: "Test Old Portfolio", holdings: [])
        storage.portfolios = [portfolio]

        let now = Date()
        let cal = Calendar.current
        // Earliest purchase date is 6 years ago
        let inceptionDate = cal.date(byAdding: .year, value: -6, to: now)!
        storage.addHolding(to: pId, symbol: "MSFT", quantity: 10, avgPrice: 100, purchaseDate: inceptionDate)

        let vm = PortfolioViewModel(scope: .portfolio(pId))
        vm.setup(stockService: StockService.shared, storageService: storage)

        XCTAssertTrue(vm.isRangeAvailable(.threeYears, now: now, calendar: cal))
        XCTAssertTrue(vm.isRangeAvailable(.fiveYears, now: now, calendar: cal))
        XCTAssertFalse(vm.isRangeAvailable(.sevenYears, now: now, calendar: cal))
        XCTAssertFalse(vm.isRangeAvailable(.tenYears, now: now, calendar: cal))
        XCTAssertTrue(vm.isRangeAvailable(.all, now: now, calendar: cal))

        // Clean up
        storage.deletePortfolio(id: pId)
    }

    @MainActor
    func testIsRangeAvailableWhenPortfolioIsOlderThan10Y() {
        let (storage, tempDir) = createTestStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pId = UUID()
        let portfolio = Portfolio(id: pId, name: "Test Decade Portfolio", holdings: [])
        storage.portfolios = [portfolio]

        let now = Date()
        let cal = Calendar.current
        // Earliest purchase date is 11 years ago
        let inceptionDate = cal.date(byAdding: .year, value: -11, to: now)!
        storage.addHolding(to: pId, symbol: "AAPL", quantity: 10, avgPrice: 50, purchaseDate: inceptionDate)

        let vm = PortfolioViewModel(scope: .portfolio(pId))
        vm.setup(stockService: StockService.shared, storageService: storage)

        XCTAssertTrue(vm.isRangeAvailable(.sevenYears, now: now, calendar: cal))
        XCTAssertTrue(vm.isRangeAvailable(.tenYears, now: now, calendar: cal))
        XCTAssertTrue(vm.isRangeAvailable(.all, now: now, calendar: cal))

        // Clean up
        storage.deletePortfolio(id: pId)
    }
}
