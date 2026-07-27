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

    func testExcelUserSharedStringsImportParsing() throws {
        let csvContent = """
        Portfolio Name,Symbol,Quantity,Avg Price,Purchase Date,Leverage
        Terry,META,2,652.4,2026/02/03,1
        Terry,SPGI,16,398.095,13-Feb,1
        Terry,RACE,7,332.0214,16-Jun,1
        """

        let imported = SpreadsheetIO.parseCSV(content: csvContent)
        XCTAssertNotNil(imported)
        XCTAssertEqual(imported?.count, 1)
        XCTAssertEqual(imported?[0].name, "Terry")
        XCTAssertEqual(imported?[0].holdings.count, 3)
        XCTAssertEqual(imported?[0].holdings[0].symbol, "META")
        XCTAssertEqual(imported?[0].holdings[0].quantity, 2)
        XCTAssertEqual(imported?[0].holdings[0].avgPrice, 652.4)
        XCTAssertEqual(imported?[0].holdings[1].symbol, "SPGI")
        XCTAssertEqual(imported?[0].holdings[1].quantity, 16)
        XCTAssertEqual(imported?[0].holdings[1].avgPrice, 398.095)
        XCTAssertEqual(imported?[0].holdings[2].symbol, "RACE")
        XCTAssertEqual(imported?[0].holdings[2].quantity, 7)
        XCTAssertEqual(imported?[0].holdings[2].avgPrice, 332.0214)
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
