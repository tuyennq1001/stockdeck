import XCTest
@testable import StockDeck

final class JapaneseFundTests: XCTestCase {

    @MainActor
    func testJapaneseMutualFundSymbolDetection() {
        let stockService = StockService.shared
        XCTAssertTrue(stockService.isJapaneseMutualFund("9I31223A"))
        XCTAssertTrue(stockService.isJapaneseMutualFund("03311187"))
        XCTAssertTrue(stockService.isJapaneseMutualFund("0331423B"))
        XCTAssertTrue(stockService.isJapaneseMutualFund("9I31223A.JP"))

        XCTAssertFalse(stockService.isJapaneseMutualFund("AAPL"))
        XCTAssertFalse(stockService.isJapaneseMutualFund("7203.T"))
        XCTAssertFalse(stockService.isJapaneseMutualFund("^GSPC"))
        XCTAssertFalse(stockService.isJapaneseMutualFund("BTC-USD"))
    }

    func testJapaneseBrokerCSVImportParsing() {
        let csvContent = """
        約定日,受渡日,ファンド名,分配金,口座,取引,買付方法,数量［口］,単価,経費,為替レート
        2024/1/30,2024/2/2,iFreeNEXT NASDAQ100インデックス,再投資型,NISAつみたて投資枠,買付,積立,"32,432","30,834",0,-
        2024/3/11,2024/3/14,iFreeNEXT NASDAQ100インデックス,受取型,NISAつみたて投資枠,買付,積立,"15,884","31,478",0,-
        2024/6/11,2024/6/14,楽天・Ｓ＆Ｐ５００インデックス・ファンド(楽天・Ｓ＆Ｐ５００),再投資型,NISAつみたて投資枠,買付,積立,"74,025","13,509",0,-
        2024/11/14,2024/11/20,auAM Nifty50インド株ファンド,再投資型,NISA成長投資枠,買付,通常,"81,633","12,250",0,-
        2025/8/19,2025/8/22,iFreeNEXT NASDAQ100インデックス,受取型,NISAつみたて投資枠,解約,,"15,884","41,791",0,-
        2026/1/8,2026/1/14,楽天・プラス・Ｓ＆Ｐ５００インデックス・ファンド(楽天・プラス・Ｓ＆Ｐ５００),再投資型,NISAつみたて投資枠,買付,積立,"28,298","17,669",0,-
        """

        let portfolios = SpreadsheetIO.parseCSV(content: csvContent)
        XCTAssertNotNil(portfolios)
        XCTAssertGreaterThanOrEqual(portfolios?.count ?? 0, 1)

        let nisaTsumitate = portfolios?.first(where: { $0.name.contains("つみたて") })
        XCTAssertNotNil(nisaTsumitate)

        // Verify iFreeNEXT NASDAQ100 net units: (32,432 + 15,884) - 15,884 = 32,432
        let nasdaqHolding = nisaTsumitate?.holdings.first(where: { $0.symbol == "04317188" || $0.symbol.contains("NASDAQ100") })
        XCTAssertNotNil(nasdaqHolding)
        XCTAssertEqual(nasdaqHolding?.quantity ?? 0, 32432, accuracy: 0.1)

        // Verify Rakuten Plus S&P500 holding (merging both 2024 and 2026 purchases)
        let plusHolding = nisaTsumitate?.holdings.first(where: { $0.symbol == "9I31223A" })
        XCTAssertNotNil(plusHolding)
        XCTAssertEqual(plusHolding?.quantity ?? 0, 102323, accuracy: 1.0)

        // Verify NISA Growth portfolio (NISA成長投資枠)
        let nisaGrowth = portfolios?.first(where: { $0.name.contains("成長") })
        XCTAssertNotNil(nisaGrowth)
        let niftyHolding = nisaGrowth?.holdings.first(where: { $0.symbol == "AY311238" })
        XCTAssertNotNil(niftyHolding)
        XCTAssertEqual(niftyHolding?.quantity ?? 0, 81633, accuracy: 0.1)
        XCTAssertEqual(niftyHolding?.avgPrice ?? 0, 12250, accuracy: 1.0)
    }

    func testParseJapaneseFundTemplateFile() {
        let templateURL = URL(fileURLWithPath: "template/tradehistory(INVST)_20260728.csv")
        guard FileManager.default.fileExists(atPath: templateURL.path) else { return }

        let portfolios = SpreadsheetIO.parseJapaneseFundCSV(from: templateURL)
        XCTAssertNotNil(portfolios)
        XCTAssertGreaterThanOrEqual(portfolios?.count ?? 0, 1)

        let allHoldings = portfolios?.flatMap { $0.holdings } ?? []
        XCTAssertGreaterThanOrEqual(allHoldings.count, 2)
    }

    func testGenerateAndParseJapaneseFundXLSXTemplate() {
        guard let xlsxData = SpreadsheetIO.generateJapaneseFundTemplateXLSXData() else {
            XCTFail("Failed to generate Japanese Fund XLSX template data")
            return
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
        try? xlsxData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let portfolios = SpreadsheetIO.parseJapaneseFundCSV(from: tempURL)
        XCTAssertNotNil(portfolios, "Parsing generated Japanese Fund XLSX template should return portfolios")
        XCTAssertGreaterThanOrEqual(portfolios?.count ?? 0, 1)

        let allHoldings = portfolios?.flatMap { $0.holdings } ?? []
        XCTAssertGreaterThanOrEqual(allHoldings.count, 3, "Generated template should contain Japanese fund holdings")
    }
}
