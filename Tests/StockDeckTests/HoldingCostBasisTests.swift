import XCTest
@testable import StockDeck

final class HoldingCostBasisTests: XCTestCase {
    func testUnknownCostBasisDoesNotCreatePnl() {
        let holding = Holding(symbol: "BTC-USD", quantity: 1, avgPrice: .nan)

        XCTAssertFalse(holding.hasKnownCostBasis)
        XCTAssertEqual(holding.costBasisLocal, 0)
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

    func testNativeCurrencyPnlAndPnlPercent() {
        let holding = Holding(symbol: "V", quantity: 10, avgPrice: 300)
        XCTAssertEqual(holding.pnl(currentPrice: 330), 300)
        XCTAssertEqual(holding.pnlPercent(currentPrice: 330), 10, accuracy: 1e-9)

        let lossHolding = Holding(symbol: "V", quantity: 10, avgPrice: 300)
        XCTAssertEqual(lossHolding.pnl(currentPrice: 270), -300)
        XCTAssertEqual(lossHolding.pnlPercent(currentPrice: 270), -10, accuracy: 1e-9)
    }

    func testJapaneseFundNativePnlAndPnlPercent() {
        // Japanese fund with scale 10,000
        let fund = Holding(symbol: "9I31223A", quantity: 100_000, avgPrice: 20_000)
        // Cost = (20,000 / 10,000) * 100,000 = 200,000 JPY
        XCTAssertTrue(fund.isJapaneseFund)
        XCTAssertEqual(fund.costBasisLocal, 200_000)

        // Current price 21,000 JPY -> Market value = (21,000 / 10,000) * 100,000 = 210,000 JPY
        // P&L = +10,000 JPY (+5.0%)
        XCTAssertEqual(fund.pnl(currentPrice: 21_000), 10_000)
        XCTAssertEqual(fund.pnlPercent(currentPrice: 21_000), 5.0, accuracy: 1e-9)
    }
}
