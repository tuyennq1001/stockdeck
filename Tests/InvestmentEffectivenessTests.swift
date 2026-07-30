import XCTest
@testable import StockDeck

@MainActor
final class InvestmentEffectivenessTests: XCTestCase {
    private var stockService: StockService!
    private var storageService: StorageService!

    override func setUp() {
        super.setUp()
        stockService = StockService.shared
        storageService = StorageService.shared
    }

    func testExcludesNilPurchaseDateHoldings() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let buyDate = today.addingTimeInterval(-365 * 86400)
        
        let holding1 = Holding(symbol: "AAPL", quantity: 10, avgPrice: 150, purchaseDate: buyDate)
        let holding2 = Holding(symbol: "MSFT", quantity: 5, avgPrice: 300, purchaseDate: nil) // excluded
        
        let result = InvestmentEffectiveness.evaluate(
            holdings: [holding1, holding2],
            stockService: stockService,
            storageService: storageService,
            today: today
        )
        
        XCTAssertEqual(result.excludedHoldingsCount, 1)
        XCTAssertFalse(result.isYoungerThan30Days)
    }

    func testJapaneseFundScalingInCashFlows() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let buyDate = today.addingTimeInterval(-365 * 86400)
        
        // Japanese mutual fund symbol where prices are quoted per 10,000 units
        // 100,000 units at avgPrice 10,000 JPY
        // costBasisLocal should be (10000 / 10000.0) * 100000 = 100,000 JPY
        let jpFundHolding = Holding(symbol: "03311187", quantity: 100_000, avgPrice: 10_000, purchaseDate: buyDate)
        XCTAssertTrue(jpFundHolding.isJapaneseFund)
        XCTAssertEqual(jpFundHolding.costBasisLocal, 100_000.0, accuracy: 1e-6)
        
        let result = InvestmentEffectiveness.evaluate(
            holdings: [jpFundHolding],
            stockService: stockService,
            storageService: storageService,
            today: today
        )
        
        XCTAssertEqual(result.excludedHoldingsCount, 0)
        XCTAssertFalse(result.isYoungerThan30Days)
    }

    func testShortPositionCashFlows() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let buyDate = today.addingTimeInterval(-365 * 86400)
        
        // Short 10 shares of TSLA at $200 (quantity = -10)
        // costBasisLocal = (200 / 1) * (-10) = -2000
        // Outflow at buyDate = -costBasisLocal = +2000 (proceeds received)
        let shortHolding = Holding(symbol: "TSLA", quantity: -10, avgPrice: 200, purchaseDate: buyDate)
        XCTAssertTrue(shortHolding.isShort)
        XCTAssertEqual(shortHolding.costBasisLocal, -2000.0, accuracy: 1e-6)
        
        let result = InvestmentEffectiveness.evaluate(
            holdings: [shortHolding],
            stockService: stockService,
            storageService: storageService,
            today: today
        )
        
        XCTAssertEqual(result.excludedHoldingsCount, 0)
        XCTAssertFalse(result.isYoungerThan30Days)
    }

    func testYoungerThan30DaysGuard() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let recentBuyDate = today.addingTimeInterval(-5 * 86400) // 5 days ago
        
        let recentHolding = Holding(symbol: "NVDA", quantity: 5, avgPrice: 400, purchaseDate: recentBuyDate)
        
        let result = InvestmentEffectiveness.evaluate(
            holdings: [recentHolding],
            stockService: stockService,
            storageService: storageService,
            today: today
        )
        
        XCTAssertTrue(result.isYoungerThan30Days)
        XCTAssertNil(result.portfolioXIRR)
        XCTAssertNil(result.benchmarkXIRR)
    }
}
