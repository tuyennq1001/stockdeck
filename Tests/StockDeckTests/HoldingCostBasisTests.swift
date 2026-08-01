import XCTest
@testable import StockDeck

final class HoldingCostBasisTests: XCTestCase {
    func testUnknownCostBasisDoesNotCreatePnl() {
        let holding = Holding(symbol: "BTC-USD", quantity: 1, avgPrice: .nan)

        XCTAssertFalse(holding.hasKnownCostBasis)
        XCTAssertTrue(holding.costBasisLocal.isNaN)
        XCTAssertEqual(holding.pnl(currentPrice: 63_000), 0)
        XCTAssertEqual(holding.pnlPercent(currentPrice: 63_000), 0)
    }

    func testKnownCostBasisStillCalculatesPnl() {
        let holding = Holding(symbol: "BTC-USD", quantity: 2, avgPrice: 50_000)

        XCTAssertTrue(holding.hasKnownCostBasis)
        XCTAssertEqual(holding.costBasisLocal, 100_000)
        XCTAssertEqual(holding.pnl(currentPrice: 60_000), 20_000)
    }

    func testUnknownCostBasisSurvivesJsonRoundTrip() throws {
        let holding = Holding(symbol: "BTC-USD", quantity: 1, avgPrice: .nan)
        let data = try JSONEncoder().encode(holding)
        let decoded = try JSONDecoder().decode(Holding.self, from: data)

        XCTAssertTrue(decoded.avgPrice.isNaN)
    }
}
