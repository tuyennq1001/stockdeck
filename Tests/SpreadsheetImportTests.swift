import XCTest
@testable import StockDeck

final class SpreadsheetImportTests: XCTestCase {

    func testCSVImportParsing() throws {
        let csvContent = """
        Portfolio Name,Symbol,Quantity,Avg Price,Purchase Date,Leverage
        Tech Growth Portfolio,AAPL,10,185.50,2024-01-15,1.0
        Tech Growth Portfolio,NVDA,5,120.00,2024-03-20,1.0
        Crypto Basket,BTC-USD,0.5,65000.00,2024-02-10,1.0
        """

        let portfolios = SpreadsheetIO.parseCSV(content: csvContent)
        XCTAssertNotNil(portfolios)
        XCTAssertEqual(portfolios?.count, 2)

        let p1 = portfolios?[0]
        XCTAssertEqual(p1?.name, "Tech Growth Portfolio")
        XCTAssertEqual(p1?.holdings.count, 2)
        XCTAssertEqual(p1?.holdings[0].symbol, "AAPL")
        XCTAssertEqual(p1?.holdings[0].quantity, 10)
        XCTAssertEqual(p1?.holdings[0].avgPrice, 185.50)

        let p2 = portfolios?[1]
        XCTAssertEqual(p2?.name, "Crypto Basket")
        XCTAssertEqual(p2?.holdings.count, 1)
        XCTAssertEqual(p2?.holdings[0].symbol, "BTC-USD")
        XCTAssertEqual(p2?.holdings[0].quantity, 0.5)
        XCTAssertEqual(p2?.holdings[0].avgPrice, 65000.0)
    }

    func testSampleXLSXDataGenerationAndParsing() throws {
        guard let xlsxData = SpreadsheetIO.generateSampleXLSXData() else {
            XCTFail("Failed to generate sample XLSX data")
            return
        }

        XCTAssertFalse(xlsxData.isEmpty)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_sample_\(UUID().uuidString).xlsx")
        try xlsxData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let imported = SpreadsheetIO.parsePortfolios(from: tempURL)
        XCTAssertNotNil(imported)
        XCTAssertEqual(imported?.count, 2)
        XCTAssertEqual(imported?[0].name, "Tech Growth Portfolio")
        XCTAssertEqual(imported?[0].holdings.count, 2)
        XCTAssertEqual(imported?[1].name, "Crypto Basket")
        XCTAssertEqual(imported?[1].holdings[0].symbol, "BTC-USD")
    }
}
