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

    func testNaNPriceInXLSXDoesNotCorruptXML() throws {
        let p = Portfolio(
            name: "Binance Portfolio",
            holdings: [
                Holding(symbol: "GOOGL", quantity: 3.0, avgPrice: 334.42, purchaseDate: Date()),
                Holding(symbol: "SOL-USD", quantity: 8.69, avgPrice: .nan, purchaseDate: nil)
            ]
        )
        guard let xlsxData = SpreadsheetIO.generatePortfoliosXLSXData([p]) else {
            XCTFail("Failed to generate XLSX data with NaN holding")
            return
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_nan_\(UUID().uuidString).xlsx")
        try xlsxData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Unzip and inspect sheet1.xml
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-p", tempURL.path, "xl/worksheets/sheet1.xml"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        task.waitUntilExit()

        let xmlData = pipe.fileHandleForReading.readDataToEndOfFile()
        let xmlString = String(data: xmlData, encoding: .utf8) ?? ""

        XCTAssertFalse(xmlString.contains("<v>nan</v>"), "XML must NOT contain <v>nan</v> which corrupts Excel")
        XCTAssertFalse(xmlString.contains("<is><t></t></is>"), "XML should avoid empty inline string nodes")

        // Also verify parsing it back succeeds
        let parsed = SpreadsheetIO.parsePortfolios(from: tempURL)
        XCTAssertNotNil(parsed)
        let holdings = parsed?.first?.holdings
        XCTAssertEqual(holdings?.count, 2)
        XCTAssertEqual(holdings?[0].symbol, "GOOGL")
        XCTAssertEqual(holdings?[1].symbol, "SOL-USD")
    }

    func testMarkdownPortfoliosRoundTrip() throws {
        let p = Portfolio(
            name: "Huyền",
            holdings: [
                Holding(symbol: "201A.T", quantity: 700, avgPrice: 170),
                Holding(symbol: "VOO", quantity: 1, avgPrice: 664),
                Holding(symbol: "9I31223A", quantity: 74025, avgPrice: 13509)
            ]
        )

        let mdString = SpreadsheetIO.generatePortfoliosMarkdownString([p])
        XCTAssertTrue(mdString.contains("| Huyền | 201A.T | 700 | 170 |"))
        XCTAssertTrue(mdString.contains("| Huyền | 9I31223A | 74025 | 13509 |"))
        XCTAssertTrue(mdString.contains("投資信託 (基準価額 / 10,000口)"))

        // Parse markdown table back to Portfolios
        let parsed = SpreadsheetIO.parseMarkdownPortfolios(content: mdString)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?[0].name, "Huyền")
        XCTAssertEqual(parsed?[0].holdings.count, 3)

        let fundHolding = parsed?[0].holdings.first(where: { $0.symbol == "9I31223A" })
        XCTAssertNotNil(fundHolding)
        XCTAssertEqual(fundHolding?.quantity, 74025)
        XCTAssertEqual(fundHolding?.avgPrice, 13509)
        XCTAssertTrue(fundHolding?.isJapaneseFund == true)
        XCTAssertEqual(fundHolding?.costBasisLocal ?? 0, (13509.0 / 10000.0) * 74025.0, accuracy: 1e-4)
    }

    func testJapaneseMutualFundRoundTripInXLSX() throws {
        let p = Portfolio(
            name: "Huyền",
            holdings: [
                Holding(symbol: "9I31223A", quantity: 74025, avgPrice: 13509)
            ]
        )

        guard let xlsxData = SpreadsheetIO.generatePortfoliosXLSXData([p]) else {
            XCTFail("Failed to generate XLSX data")
            return
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_fund_\(UUID().uuidString).xlsx")
        try xlsxData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let parsed = SpreadsheetIO.parsePortfolios(from: tempURL)
        XCTAssertNotNil(parsed)
        let fund = parsed?.first?.holdings.first
        XCTAssertEqual(fund?.symbol, "9I31223A")
        XCTAssertEqual(fund?.quantity, 74025)
        XCTAssertEqual(fund?.avgPrice, 13509)
        XCTAssertTrue(fund?.isJapaneseFund == true)
        XCTAssertEqual(fund?.costBasisLocal ?? 0, (13509.0 / 10000.0) * 74025.0, accuracy: 1e-4)
    }

    func testTransactionsXLSXDataGeneration() throws {
        let date1 = Date(timeIntervalSince1970: 1705300000) // ~2024-01-15
        let date2 = Date(timeIntervalSince1970: 1710900000) // ~2024-03-20
        let p = Portfolio(
            name: "Core Portfolio",
            transactions: [
                Transaction(
                    date: date1,
                    symbol: "AAPL",
                    type: .buy,
                    quantity: 10,
                    price: 185.5,
                    account: "Tokutei",
                    notes: "First buy"
                ),
                Transaction(
                    date: date2,
                    symbol: "9I31223A",
                    type: .buy,
                    quantity: 50000,
                    price: 15000,
                    account: "NISA Growth",
                    notes: "Monthly investment"
                )
            ]
        )

        guard let xlsxData = SpreadsheetIO.generateTransactionsXLSXData([p]) else {
            XCTFail("Failed to generate transactions XLSX data")
            return
        }

        XCTAssertFalse(xlsxData.isEmpty)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_tx_\(UUID().uuidString).xlsx")
        try xlsxData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Unzip and inspect sheet1.xml
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-p", tempURL.path, "xl/worksheets/sheet1.xml"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let xml = String(data: outData, encoding: .utf8) ?? ""
        XCTAssertTrue(xml.contains("AAPL"))
        XCTAssertTrue(xml.contains("9I31223A"))
        XCTAssertTrue(xml.contains("Core Portfolio"))
        XCTAssertTrue(xml.contains("NISA Growth"))
        XCTAssertTrue(xml.contains("Tokutei"))
    }

    func testTransactionsMarkdownGeneration() throws {
        let date1 = Date(timeIntervalSince1970: 1705300000)
        let p = Portfolio(
            name: "My Tech Portfolio",
            transactions: [
                Transaction(
                    date: date1,
                    symbol: "NVDA",
                    type: .buy,
                    quantity: 5,
                    price: 120.0,
                    account: "Taxable",
                    notes: "Test | note with pipe"
                )
            ]
        )

        let md = SpreadsheetIO.generateTransactionsMarkdownString([p])
        XCTAssertTrue(md.contains("# StockDeck Transactions Export"))
        XCTAssertTrue(md.contains("My Tech Portfolio"))
        XCTAssertTrue(md.contains("NVDA"))
        XCTAssertTrue(md.contains("Buy"))
        XCTAssertTrue(md.contains("Taxable"))
        XCTAssertTrue(md.contains("Test \\| note with pipe"))

        guard let mdData = SpreadsheetIO.generateTransactionsMarkdownData([p]) else {
            XCTFail("Failed to generate markdown data")
            return
        }
        XCTAssertFalse(mdData.isEmpty)
    }
}
