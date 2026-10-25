import XCTest
@testable import StockDeck

@MainActor
final class AutoExportServiceTests: XCTestCase {

    func testPeriodKeyCalculationBiweeklyFirstHalf() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        var comps1 = DateComponents()
        comps1.year = 2026; comps1.month = 10; comps1.day = 1
        let date1 = cal.date(from: comps1)!
        XCTAssertEqual(AutoExportService.periodKey(for: date1, frequency: .biweekly), "2026-10-01")

        var comps14 = DateComponents()
        comps14.year = 2026; comps14.month = 10; comps14.day = 14
        let date14 = cal.date(from: comps14)!
        XCTAssertEqual(AutoExportService.periodKey(for: date14, frequency: .biweekly), "2026-10-01")
    }

    func testPeriodKeyCalculationBiweeklySecondHalf() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        var comps15 = DateComponents()
        comps15.year = 2026; comps15.month = 10; comps15.day = 15
        let date15 = cal.date(from: comps15)!
        XCTAssertEqual(AutoExportService.periodKey(for: date15, frequency: .biweekly), "2026-10-15")

        var comps31 = DateComponents()
        comps31.year = 2026; comps31.month = 10; comps31.day = 31
        let date31 = cal.date(from: comps31)!
        XCTAssertEqual(AutoExportService.periodKey(for: date31, frequency: .biweekly), "2026-10-15")
    }

    func testPeriodKeyCalculationMonthly() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 25
        let date = cal.date(from: comps)!
        XCTAssertEqual(AutoExportService.periodKey(for: date, frequency: .monthly), "2026-05-01")
    }

    func testExportAppDataRoundTripWithAutoExportFields() {
        let storage = StorageService()
        storage.autoExportEnabled = true
        storage.autoExportFrequency = .monthly
        let testDate = Date(timeIntervalSince1970: 1_700_000_000)
        storage.lastAutoExportDate = testDate
        storage.lastAutoExportPeriodKey = "2026-10-01"

        let exported = storage.exportAppData()
        XCTAssertEqual(exported.autoExportEnabled, true)
        XCTAssertEqual(exported.autoExportFrequency, "monthly")
        XCTAssertEqual(exported.lastAutoExportDate, testDate)
        XCTAssertEqual(exported.lastAutoExportPeriodKey, "2026-10-01")

        let freshStorage = StorageService()
        freshStorage.applyAppData(exported)
        XCTAssertEqual(freshStorage.autoExportEnabled, true)
        XCTAssertEqual(freshStorage.autoExportFrequency, .monthly)
        XCTAssertEqual(freshStorage.lastAutoExportDate, testDate)
        XCTAssertEqual(freshStorage.lastAutoExportPeriodKey, "2026-10-01")
    }

    func testBuildExportPayloadFormattingAndValuation() throws {
        let storage = StorageService()
        storage.preferredCurrency = "USD"

        let holding1 = Holding(
            symbol: "AAPL",
            quantity: 10,
            avgPrice: 150,
            purchaseDate: Date(timeIntervalSince1970: 1_700_000_000),
            account: "Taxable"
        )
        // Japanese mutual fund: 10000 units, avgPrice 20000 (scale 10000 -> 2.0 per unit)
        let fundSymbol = "0331418A"
        let holding2 = Holding(
            symbol: fundSymbol,
            quantity: 10000,
            avgPrice: 20000,
            purchaseDate: Date(timeIntervalSince1970: 1_700_000_000),
            account: "NISA"
        )
        // Binance-like position with missing cost basis (avgPrice = 0)
        let holdingMissingCost = Holding(
            symbol: "BTC",
            quantity: 0.5,
            avgPrice: 0.0,
            account: "-"
        )

        let tx1 = PortfolioTransaction(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            symbol: "AAPL",
            type: .buy,
            quantity: 10,
            price: 150,
            account: "Taxable",
            notes: "Test buy"
        )
        let txDividend = PortfolioTransaction(
            date: Date(timeIntervalSince1970: 1_705_000_000),
            symbol: "AAPL",
            type: .dividend,
            quantity: 0,
            price: 0,
            amount: 25.50,
            account: nil,
            notes: "Q4 Dividend"
        )

        let closedTrade1 = ClosedTrade(
            symbol: "NVDA",
            quantity: 20,
            buyPrice: 100,
            sellPrice: 130,
            buyDate: Date(timeIntervalSince1970: 1_690_000_000),
            sellDate: Date(timeIntervalSince1970: 1_700_000_000),
            account: "Taxable"
        )

        let portfolio = Portfolio(
            id: UUID(),
            name: "Main Portfolio",
            holdings: [holding1, holding2, holdingMissingCost],
            closedTrades: [closedTrade1],
            transactions: [tx1, txDividend]
        )
        storage.portfolios = [portfolio]

        let stockService = StockService.shared
        let payload = AutoExportService.buildExportPayload(
            storageService: storage,
            stockService: stockService,
            date: Date(timeIntervalSince1970: 1_729_000_000)
        )

        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload.summary.totalPortfolioCount, 1)
        XCTAssertEqual(payload.portfolios.count, 1)
        XCTAssertTrue(payload.summary.hasIncompleteCostBasis)

        let expPortfolio = payload.portfolios[0]
        XCTAssertEqual(expPortfolio.name, "Main Portfolio")
        XCTAssertEqual(expPortfolio.holdings.count, 3)
        XCTAssertEqual(expPortfolio.closedTrades.count, 1)
        XCTAssertEqual(expPortfolio.transactions.count, 2)
        XCTAssertTrue(expPortfolio.hasIncompleteCostBasis)

        // Holding 1: AAPL
        let expH1 = expPortfolio.holdings.first { $0.symbol == "AAPL" }
        XCTAssertNotNil(expH1)
        XCTAssertEqual(expH1?.quantity, 10)
        XCTAssertEqual(expH1?.avgPrice, 150)
        XCTAssertEqual(expH1?.costBasis, 1500)
        XCTAssertEqual(expH1?.costBasisMissing, false)
        XCTAssertEqual(expH1?.currency, "USD")
        XCTAssertEqual(expH1?.account, "Taxable")
        XCTAssertEqual(expH1?.assetType, "EQUITY")

        // Holding 2: Japanese mutual fund
        let expH2 = expPortfolio.holdings.first { $0.symbol == fundSymbol }
        XCTAssertNotNil(expH2)
        XCTAssertEqual(expH2?.quantity, 10000)
        XCTAssertEqual(expH2?.costBasis, 20000)
        XCTAssertEqual(expH2?.costBasisMissing, false)
        XCTAssertEqual(expH2?.currency, "JPY")
        XCTAssertEqual(expH2?.account, "NISA")
        XCTAssertEqual(expH2?.assetType, "MUTUAL_FUND")
        XCTAssertEqual(expH2?.exchange, "TSE")

        // Holding 3: Missing cost basis
        let expH3 = expPortfolio.holdings.first { $0.symbol == "BTC" }
        XCTAssertNotNil(expH3)
        XCTAssertEqual(expH3?.quantity, 0.5)
        XCTAssertEqual(expH3?.costBasisMissing, true)
        XCTAssertNil(expH3?.costBasis)
        XCTAssertNil(expH3?.unrealizedPnl)
        XCTAssertNil(expH3?.unrealizedPnlPercent)
        XCTAssertEqual(expH3?.account, "") // Normalized from "-"

        // Closed Trade
        let expCT = expPortfolio.closedTrades[0]
        XCTAssertEqual(expCT.symbol, "NVDA")
        XCTAssertEqual(expCT.quantity, 20)
        XCTAssertEqual(expCT.buyPrice, 100)
        XCTAssertEqual(expCT.sellPrice, 130)
        XCTAssertEqual(expCT.costBasis, 2000)
        XCTAssertEqual(expCT.proceeds, 2600)
        XCTAssertEqual(expCT.realizedPnl, 600)
        XCTAssertEqual(expCT.realizedPnlPercent, 30)
        XCTAssertEqual(expCT.account, "Taxable")

        // Transactions
        let expTx1 = expPortfolio.transactions.first { $0.type == "BUY" }
        XCTAssertNotNil(expTx1)
        XCTAssertEqual(expTx1?.symbol, "AAPL")
        XCTAssertEqual(expTx1?.quantity, 10)
        XCTAssertEqual(expTx1?.price, 150)
        XCTAssertEqual(expTx1?.amount, 1500)
        XCTAssertEqual(expTx1?.account, "Taxable")
        XCTAssertEqual(expTx1?.notes, "Test buy")

        let expTxDiv = expPortfolio.transactions.first { $0.type == "DIVIDEND" }
        XCTAssertNotNil(expTxDiv)
        XCTAssertEqual(expTxDiv?.symbol, "AAPL")
        XCTAssertEqual(expTxDiv?.amount, 25.50)
        XCTAssertEqual(expTxDiv?.account, "") // Normalized from nil
        XCTAssertEqual(expTxDiv?.notes, "Q4 Dividend")

        // JSON roundtrip test
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PortfolioExportPayload.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.portfolios.count, 1)
        XCTAssertEqual(decoded.summary.totalPortfolioCount, 1)
        XCTAssertEqual(decoded.portfolios[0].name, "Main Portfolio")
        XCTAssertEqual(decoded.portfolios[0].closedTrades.count, 1)
    }

    func testExportDirectoryResolution() {
        let baseDir = AutoExportService.baseDirectoryURL
        XCTAssertTrue(baseDir.isFileURL)
        XCTAssertFalse(baseDir.path.isEmpty)

        let latestFile = AutoExportService.latestExportFileURL
        XCTAssertEqual(latestFile.lastPathComponent, "portfolio_export_latest.json")

        let archiveDir = AutoExportService.archiveDirectoryURL
        XCTAssertEqual(archiveDir.lastPathComponent, "Exports")
    }
}
