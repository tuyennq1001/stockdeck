import XCTest
@testable import StockDeck

final class RakutenTransactionImportTests: XCTestCase {

    func testDecodeUserBackup() throws {
        let path = ("~/Library/Application Support/StockDeck/data.corrupted-20260816-000357.json" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(StorageService.AppData.self, from: data)
        print("Decoded portfolios: \(decoded.portfolios.count), watchlists: \(decoded.watchlists?.count ?? 0)")
        XCTAssertEqual(decoded.portfolios.count, 4)
    }

    func testHuyenMutualFundsCSVImport() throws {
        let fileURL = URL(fileURLWithPath: "template/transaction/Huyen_tradehistory(INVST)_20260822 (1).csv")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            XCTFail("Missing template file: \(fileURL.path)")
            return
        }

        guard let portfolios = SpreadsheetIO.parseJapaneseFundCSV(from: fileURL) else {
            XCTFail("Failed to parse Huyen INVST CSV")
            return
        }

        XCTAssertFalse(portfolios.isEmpty)

        // NISA Tsumitate (NISAつみたて投資枠) contains Rakuten Plus S&P 500 (9I31223A)
        let tsumitate = portfolios.first { $0.name.contains("つみたて") }
        XCTAssertNotNil(tsumitate)
        let sp500Holdings = tsumitate?.holdings.filter { $0.symbol == "9I31223A" } ?? []
        XCTAssertFalse(sp500Holdings.isEmpty)
        let totalSp500Qty = sp500Holdings.reduce(0.0) { $0 + $1.quantity }
        XCTAssertGreaterThan(totalSp500Qty, 400_000)

        // iFreeNEXT NASDAQ100 was fully sold off (32432 bought, 15884 bought, 15884 sold, 32432 sold = 0 net)
        let nasdaqHoldings = tsumitate?.holdings.filter { $0.symbol == "04317188" } ?? []
        XCTAssertEqual(nasdaqHoldings.count, 0)

        // NISA Growth (NISA成長投資枠) contains auAM Nifty50 (AY311238)
        let growth = portfolios.first { $0.name.contains("成長") }
        XCTAssertNotNil(growth)
        let niftyHoldings = growth?.holdings.filter { $0.symbol == "AY311238" } ?? []
        XCTAssertFalse(niftyHoldings.isEmpty)
        let totalNiftyQty = niftyHoldings.reduce(0.0) { $0 + $1.quantity }
        XCTAssertEqual(totalNiftyQty, 540_100, accuracy: 0.1)
    }

    func testHuyenJapaneseStocksCSVImport() throws {
        let fileURL = URL(fileURLWithPath: "template/transaction/Huyen_tradehistory(JP)_20260822 (1).csv")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            XCTFail("Missing template file: \(fileURL.path)")
            return
        }

        guard let portfolios = SpreadsheetIO.parseJapaneseFundCSV(from: fileURL) else {
            XCTFail("Failed to parse Huyen JP CSV")
            return
        }

        // 1489 was bought 150 shares and sold 150 shares -> 0 active
        let growth = portfolios.first { $0.name.contains("成長") }
        XCTAssertNotNil(growth)
        let holdings1489 = growth?.holdings.filter { $0.symbol == "1489.T" } ?? []
        XCTAssertEqual(holdings1489.count, 0)

        // 201A.T has 700 shares active @ 170.0 JPY (verify price is NOT 0.0 and date is NOT empty)
        let holdings201A = growth?.holdings.filter { $0.symbol == "201A.T" } ?? []
        XCTAssertEqual(holdings201A.count, 1)
        let h = try XCTUnwrap(holdings201A.first)
        XCTAssertEqual(h.quantity, 700, accuracy: 0.1)
        XCTAssertEqual(h.avgPrice, 170.0, accuracy: 0.1)
        XCTAssertNotNil(h.purchaseDate)
    }

    func testHuyenUSStocksCSVImport() throws {
        let fileURL = URL(fileURLWithPath: "template/transaction/Huyen_tradehistory(US)_20260822 (1).csv")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            XCTFail("Missing template file: \(fileURL.path)")
            return
        }

        guard let portfolios = SpreadsheetIO.parseJapaneseFundCSV(from: fileURL) else {
            XCTFail("Failed to parse Huyen US CSV")
            return
        }

        let growth = portfolios.first { $0.name.contains("成長") }
        XCTAssertNotNil(growth)
        let holdings = growth?.holdings ?? []

        // Verify active positions exist for VOO, GOOG, META, V, RACE
        let symbols = Set(holdings.map(\.symbol))
        XCTAssertTrue(symbols.contains("VOO"))
        XCTAssertTrue(symbols.contains("GOOG"))
        XCTAssertTrue(symbols.contains("META"))
        XCTAssertTrue(symbols.contains("V"))
        XCTAssertTrue(symbols.contains("RACE"))

        // SOXL was bought and fully sold -> 0 active
        XCTAssertFalse(symbols.contains("SOXL"))
    }

    private func findTemplateURL(matching: String) -> URL? {
        let dir = URL(fileURLWithPath: "template/transaction")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        if let match = files.first(where: { $0.localizedCaseInsensitiveContains(matching) && $0.hasSuffix(".csv") }) {
            return dir.appendingPathComponent(match)
        }
        return nil
    }

    func testTuyenChineseStocksCSVImport() throws {
        guard let fileURL = findTemplateURL(matching: "tradehistory(CH)") else {
            XCTFail("Missing template file matching tradehistory(CH)")
            return
        }

        // In this file 02846 was bought 4000 shares and fully sold in 3 batches (2000, 1900, 100) -> 0 active
        let portfolios = SpreadsheetIO.parseJapaneseFundCSV(from: fileURL)
        XCTAssertTrue(portfolios == nil || portfolios?.isEmpty == true || portfolios?.allSatisfy({ $0.holdings.isEmpty }) == true)

        // Test mock CSV with active HK holding
        let mockHKCSV = """
        約定日,受渡日,銘柄コード,銘柄名,市場,通貨,取引区分,口座区分,数量［株］,単価,約定代金,為替レート,現地手数料,諸費用,国内手数料［円］,税金等［円］,受渡金額［円］
        "2024/01/19","2024/01/23","02846","iShares CSI300 ETF","香港","HKドル","買付","NISA成長投資枠","4,000","23.2000","92,800.00","19.08","0.00","0.00","0","0","1,770,624"
        "2024/06/27","2024/07/01","02846","iShares CSI300 ETF","香港","HKドル","売付","NISA成長投資枠","1,000","24.5000","24,500.00","20.42","0.00","0.00","0","0","500,290"
        """

        let parsed = SpreadsheetIO.parseCSV(content: mockHKCSV)
        XCTAssertNotNil(parsed)
        let hkHoldings = parsed?.first?.holdings ?? []
        XCTAssertEqual(hkHoldings.count, 1)
        XCTAssertEqual(hkHoldings.first?.symbol, "2846.HK")
        XCTAssertEqual(hkHoldings.first?.quantity ?? 0, 3000, accuracy: 0.1)
        XCTAssertEqual(hkHoldings.first?.avgPrice ?? 0, 23.2, accuracy: 0.1)
    }

    func testTuyenMutualFundsCSVImportWithHifumiPlus() throws {
        guard let fileURL = findTemplateURL(matching: "tuyen_tradehistory(INVST)") else {
            XCTFail("Missing template file matching tuyen_tradehistory(INVST)")
            return
        }

        guard let portfolios = SpreadsheetIO.parseJapaneseFundCSV(from: fileURL) else {
            XCTFail("Failed to parse Tuyen INVST CSV")
            return
        }

        // Hifumi Plus was bought 97 + 96 and sold 193 -> 0 net
        let allHoldings = portfolios.flatMap(\.holdings)
        let hifumi = allHoldings.filter { $0.symbol == "9C311125" }
        XCTAssertEqual(hifumi.count, 0)

        // iTrust India (42311184) and Rakuten Plus S&P 500 (9I31223A) remain active
        let india = allHoldings.filter { $0.symbol == "42311184" }
        XCTAssertFalse(india.isEmpty)
        let totalIndiaQty = india.reduce(0.0) { $0 + $1.quantity }
        XCTAssertEqual(totalIndiaQty, 197_386, accuracy: 0.1)

        let plusSP = allHoldings.filter { $0.symbol == "9I31223A" }
        XCTAssertFalse(plusSP.isEmpty)
        let totalSPQty = plusSP.reduce(0.0) { $0 + $1.quantity }
        XCTAssertEqual(totalSPQty, 261_006, accuracy: 0.1)
    }

    func testTuyenUSStocksCSVImportWithTransferOutAndIn() throws {
        guard let fileURL = findTemplateURL(matching: "tuyen_tradehistory(US)") else {
            XCTFail("Missing template file matching tuyen_tradehistory(US)")
            return
        }

        guard let portfolios = SpreadsheetIO.parseJapaneseFundCSV(from: fileURL) else {
            XCTFail("Failed to parse Tuyen US CSV")
            return
        }

        // SPGI was bought 16 shares in NISA成長投資枠, then 出庫 16 shares on 2026/7/1 -> 0 remaining in NISA!
        let growth = portfolios.first { $0.name.contains("成長") }
        XCTAssertNotNil(growth)
        let nisaSPGI = growth?.holdings.filter { $0.symbol == "SPGI" } ?? []
        XCTAssertEqual(nisaSPGI.count, 0, "SPGI transferred out of NISA must have 0 remaining in NISA")

        // SPGI and MBGL are transferred in (入庫) to 一般 account with allocated cost basis
        let general = portfolios.first { $0.name == "一般" }
        XCTAssertNotNil(general)
        let generalSPGI = general?.holdings.filter { $0.symbol == "SPGI" } ?? []
        XCTAssertEqual(generalSPGI.count, 1)
        let spgi = try XCTUnwrap(generalSPGI.first)
        XCTAssertEqual(spgi.quantity, 16)
        XCTAssertGreaterThan(spgi.avgPrice, 370.0) // 95.6% of original ~$398.17 -> ~$380.65

        // If MBGL was subsequently sold in the file (e.g. 2026/09/04), it will be in closedTrades
        if let mbgl = general?.holdings.first(where: { $0.symbol == "MBGL" }) {
            XCTAssertEqual(mbgl.quantity, 16)
            XCTAssertGreaterThan(mbgl.avgPrice, 15.0) // 4.4% of original ~$398.17 -> ~$17.52
            let totalCost = (spgi.quantity * spgi.avgPrice) + (mbgl.quantity * mbgl.avgPrice)
            XCTAssertEqual(totalCost, 6370.72, accuracy: 1.0)
        } else if let mbglClosed = general?.closedTrades.first(where: { $0.symbol == "MBGL" }) {
            XCTAssertEqual(mbglClosed.quantity, 16)
            XCTAssertGreaterThan(mbglClosed.buyPrice, 15.0)
            let totalCost = (spgi.quantity * spgi.avgPrice) + (mbglClosed.quantity * mbglClosed.buyPrice)
            XCTAssertEqual(totalCost, 6370.72, accuracy: 1.0)
        } else {
            XCTFail("MBGL not found in general account holdings or closed trades")
        }
    }

    @MainActor
    func testMultiFileBatchImport() throws {
        let urls = [
            URL(fileURLWithPath: "template/transaction/Huyen_tradehistory(INVST)_20260822 (1).csv"),
            URL(fileURLWithPath: "template/transaction/Huyen_tradehistory(JP)_20260822 (1).csv"),
            URL(fileURLWithPath: "template/transaction/Huyen_tradehistory(US)_20260822 (1).csv")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }

        guard urls.count == 3 else {
            XCTFail("Missing some Huyen transaction template files")
            return
        }

        let result = PortfolioIO.parseFiles(urls: urls)
        XCTAssertNotNil(result)

        let items = result?.items ?? []
        XCTAssertFalse(items.isEmpty)

        // Should include both funds (AY311238, 9I31223A) and stocks (201A.T, VOO, GOOG, META, V, RACE)
        let symbols = Set(items.map(\.holding.symbol))
        XCTAssertTrue(symbols.contains("201A.T"))
        XCTAssertTrue(symbols.contains("VOO"))
        XCTAssertTrue(symbols.contains("GOOG"))
        XCTAssertTrue(symbols.contains("AY311238"))
        XCTAssertTrue(symbols.contains("9I31223A"))

        // Verify isFund is accurately tagged per item
        let fundItem = items.first { $0.holding.symbol == "9I31223A" }
        XCTAssertEqual(fundItem?.isFund, true)

        let stockItem = items.first { $0.holding.symbol == "VOO" }
        XCTAssertEqual(stockItem?.isFund, false)
    }

    @MainActor
    func testMBGLSellTradeReportsAllClosedStatus() throws {
        let userCSV = """
        約定日,受渡日,ティッカー,銘柄名,口座,取引区分,売買区分,信用区分,弁済期限,決済通貨,数量［株］,単価［USドル］,約定代金［USドル］,為替レート,手数料［USドル］,税金［USドル］,受渡金額［USドル］,受渡金額［円］
        "2026/9/1","2026/9/3","MBGL","MOBILITY GLOBAL","特定","現物","売付","-","-","米ドル","16","20.3350","325.36","159.520","1.47","0.14","323.75","-"
        """

        let rows = userCSV.components(separatedBy: .newlines).map { line in
            SpreadsheetIO.splitCSVLine(line, delimiter: ",")
        }

        let status = SpreadsheetIO.parseJapaneseBrokerCSVStatus(rows: rows)
        switch status {
        case .allTradesClosed(let count):
            XCTAssertEqual(count, 1)
        default:
            XCTFail("Expected allTradesClosed status, got \(status)")
        }

        let parsedPortfolios = SpreadsheetIO.parseJapaneseBrokerCSV(rows: rows)
        XCTAssertNil(parsedPortfolios, "Sell-only trade should produce 0 active holdings")
    }

    @MainActor
    func testCombinedMultiFileBuyAndSubsequentSell() throws {
        guard let historyURL = findTemplateURL(matching: "tuyen_tradehistory(US)") else {
            XCTFail("Missing template file matching tuyen_tradehistory(US)")
            return
        }

        // Create temporary CSV file for the 2026/9/1 MBGL sell trade
        let tempSellURL = FileManager.default.temporaryDirectory.appendingPathComponent("MBGL_sell_\(UUID().uuidString).csv")
        let sellCSV = """
        約定日,受渡日,ティッカー,銘柄名,口座,取引区分,売買区分,信用区分,弁済期限,決済通貨,数量［株］,単価［USドル］,約定代金［USドル］,為替レート,手数料［USドル］,税金［USドル］,受渡金額［USドル］,受渡金額［円］
        "2026/9/1","2026/9/3","MBGL","MOBILITY GLOBAL","一般","現物","売付","-","-","米ドル","16","20.3350","325.36","159.520","1.47","0.14","323.75","-"
        """
        try sellCSV.write(to: tempSellURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempSellURL) }

        // Combined multi-file import
        let result = PortfolioIO.parseFiles(urls: [historyURL, tempSellURL])
        XCTAssertNotNil(result)

        let items = result?.items ?? []
        let symbols = Set(items.map(\.holding.symbol))

        // SPGI should still be active in 一般
        XCTAssertTrue(symbols.contains("SPGI"))

        // MBGL was sold 16 shares on 2026/9/1 -> should NOT be in active holdings!
        XCTAssertFalse(symbols.contains("MBGL"), "MBGL was sold out and must not appear in active positions")
    }
}

