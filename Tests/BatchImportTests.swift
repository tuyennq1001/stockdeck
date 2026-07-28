import XCTest
@testable import StockDeck

final class BatchImportTests: XCTestCase {

    func testParseBatchHoldingsSymbolList() {
        let text = "AAPL, NVDA, TSLA, 9I31223A, 03311187"
        let holdings = SpreadsheetIO.parseBatchHoldings(from: text)

        XCTAssertEqual(holdings.count, 5)
        XCTAssertEqual(holdings[0].symbol, "AAPL")
        XCTAssertEqual(holdings[1].symbol, "NVDA")
        XCTAssertEqual(holdings[2].symbol, "TSLA")
        XCTAssertEqual(holdings[3].symbol, "9I31223A") // 楽天・プラス・S&P500
        XCTAssertEqual(holdings[4].symbol, "03311187") // eMAXIS Slim S&P500
    }

    func testParseBatchHoldingsWithQtyAndPrice() {
        let text = """
        AAPL 10 185.50
        NVDA 5 120.00
        9I31223A 28298 17669
        03311187 50000 44607
        """

        let holdings = SpreadsheetIO.parseBatchHoldings(from: text)

        XCTAssertEqual(holdings.count, 4)

        XCTAssertEqual(holdings[0].symbol, "AAPL")
        XCTAssertEqual(holdings[0].quantity, 10)
        XCTAssertEqual(holdings[0].avgPrice, 185.50)

        XCTAssertEqual(holdings[2].symbol, "9I31223A")
        XCTAssertEqual(holdings[2].quantity, 28298)
        XCTAssertEqual(holdings[2].avgPrice, 17669)
    }

    func testParseBatchHoldingsJapaneseFundNameResolution() {
        let text = """
        楽天・プラス・Ｓ＆Ｐ５００インデックス・ファンド 28298 17669
        eMAXIS Slim米国株式(S&P500) 50000 44607
        """

        let holdings = SpreadsheetIO.parseBatchHoldings(from: text)

        XCTAssertEqual(holdings.count, 2)
        XCTAssertEqual(holdings[0].symbol, "9I31223A")
        XCTAssertEqual(holdings[0].quantity, 28298)
        XCTAssertEqual(holdings[0].avgPrice, 17669)

        XCTAssertEqual(holdings[1].symbol, "03311187")
        XCTAssertEqual(holdings[1].quantity, 50000)
        XCTAssertEqual(holdings[1].avgPrice, 44607)
    }

    @MainActor
    func testAddHoldingsBatchPositionMerging() {
        let storageService = StorageService.shared
        let pId = UUID()
        let initialPortfolio = Portfolio(id: pId, name: "Test Portfolio", holdings: [
            Holding(symbol: "AAPL", quantity: 10, avgPrice: 150.0),
            Holding(symbol: "9I31223A", quantity: 10000, avgPrice: 17000.0)
        ])

        storageService.portfolios.append(initialPortfolio)

        let newBatch = [
            Holding(symbol: "AAPL", quantity: 10, avgPrice: 200.0), // Should result in qty=20, avgPrice=175.0
            Holding(symbol: "9I31223A", quantity: 10000, avgPrice: 18000.0), // Should result in qty=20000, avgPrice=17500.0
            Holding(symbol: "NVDA", quantity: 5, avgPrice: 120.0) // New holding
        ]

        storageService.addHoldingsBatch(newBatch, to: pId)

        guard let updatedP = storageService.portfolios.first(where: { $0.id == pId }) else {
            XCTFail("Portfolio not found")
            return
        }

        XCTAssertEqual(updatedP.holdings.count, 3)

        let aapl = updatedP.holdings.first(where: { $0.symbol == "AAPL" })
        XCTAssertNotNil(aapl)
        XCTAssertEqual(aapl?.quantity ?? 0, 20)
        XCTAssertEqual(aapl?.avgPrice ?? 0, 175.0, accuracy: 0.01)

        let fund = updatedP.holdings.first(where: { $0.symbol == "9I31223A" })
        XCTAssertNotNil(fund)
        XCTAssertEqual(fund?.quantity ?? 0, 20000)
        XCTAssertEqual(fund?.avgPrice ?? 0, 17500.0, accuracy: 0.1)

        let nvda = updatedP.holdings.first(where: { $0.symbol == "NVDA" })
        XCTAssertNotNil(nvda)
        XCTAssertEqual(nvda?.quantity ?? 0, 5)

        // Clean up test portfolio
        storageService.portfolios.removeAll(where: { $0.id == pId })
    }
}
