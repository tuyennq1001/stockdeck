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
        XCTAssertFalse(stockService.isJapaneseMutualFund("GOOGL"))
        XCTAssertFalse(stockService.isJapaneseMutualFund("PLTR"))
        XCTAssertFalse(stockService.isJapaneseMutualFund("AMZNF"))
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

        // Verify iFreeNEXT NASDAQ100 net units across lots: (32,432 + 15,884) - 15,884 = 32,432
        let totalNasdaqQty = nisaTsumitate?.holdings.filter({ $0.symbol == "04317188" || $0.symbol.contains("NASDAQ100") }).reduce(0) { $0 + $1.quantity } ?? 0
        XCTAssertEqual(totalNasdaqQty, 32432, accuracy: 0.1)

        // Verify Rakuten Plus S&P500 holding (merging both 2024 and 2026 purchases across lots)
        let totalPlusQty = nisaTsumitate?.holdings.filter({ $0.symbol == "9I31223A" }).reduce(0) { $0 + $1.quantity } ?? 0
        XCTAssertEqual(totalPlusQty, 102323, accuracy: 1.0)

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

    func testParseJapaneseFundHistory() {
        // Mirrors the real Yahoo Japan `/quote/<code>/history` table: a date in
        // the `<th scope="row">` header, then 基準価額 as the first numeric cell.
        let html = """
        <table>
        <tr class="_Table__row_t3ju0_24"><th scope="row" class="_Table__header_t3ju0_1 styles-module-scss-module__001sWW__FundsHistoryContainer__cell">2026/8/6</th><td class="_Table__data_t3ju0_1"><span class="_StyledNumber_1arhg_1 _StyledNumber--vertical_1arhg_24"><span class="_StyledNumber__item_1arhg_6 _StyledNumber__item--small_1arhg_40"><span class="_StyledNumber__value_1arhg_9">19,940</span></span></span></td><td class="_Table__data_t3ju0_1"><span class="_StyledNumber__value_1arhg_9">-4</span></td></tr>
        <tr class="_Table__row_t3ju0_24 _Table__row--even_t3ju0_24"><th scope="row" class="_Table__header_t3ju0_1 styles-module-scss-module__001sWW__FundsHistoryContainer__cell">2026/8/5</th><td class="_Table__data_t3ju0_1"><span class="_StyledNumber__value_1arhg_9">19,944</span></td><td class="_Table__data_t3ju0_1"><span class="_StyledNumber__value_1arhg_9">+368</span></td></tr>
        <tr class="_Table__row_t3ju0_24"><th scope="row" class="_Table__header_t3ju0_1 styles-module-scss-module__001sWW__FundsHistoryContainer__cell">2026/8/3</th><td class="_Table__data_t3ju0_1"><span class="_StyledNumber__value_1arhg_9">19,090</span></td><td class="_Table__data_t3ju0_1"><span class="_StyledNumber__value_1arhg_9">-466</span></td></tr>
        </table>
        """

        let points = StockService.parseJapaneseFundHistory(html: html)

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].close, 19090, accuracy: 0.001)
        XCTAssertEqual(points[1].close, 19944, accuracy: 0.001)
        XCTAssertEqual(points[2].close, 19940, accuracy: 0.001)
        XCTAssertEqual(points.map(\.date).sorted(), points.map(\.date))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let firstDay = calendar.dateComponents([.day], from: points[0].date).day
        XCTAssertEqual(firstDay, 3)
    }
}
