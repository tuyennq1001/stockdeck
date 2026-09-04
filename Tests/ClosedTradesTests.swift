import XCTest
@testable import StockDeck

final class ClosedTradesTests: XCTestCase {

    func testClosedTradeCalculations() {
        let trade = ClosedTrade(
            symbol: "AAPL",
            quantity: 10,
            buyPrice: 150.0,
            sellPrice: 200.0,
            buyDate: Calendar.current.date(byAdding: .day, value: -30, to: Date()),
            sellDate: Date(),
            account: "Taxable"
        )

        XCTAssertEqual(trade.costBasis, 1500.0)
        XCTAssertEqual(trade.proceeds, 2000.0)
        XCTAssertEqual(trade.realizedPnl, 500.0)
        XCTAssertEqual(trade.realizedPnlPercent, (500.0 / 1500.0) * 100, accuracy: 1e-4)
        XCTAssertEqual(trade.holdingPeriodDays, 30)
    }

    func testClosedTradeLeveragedShortCalculations() {
        let trade = ClosedTrade(
            symbol: "TSLA",
            quantity: 5,
            buyPrice: 200.0,
            sellPrice: 180.0,
            buyDate: Date(),
            sellDate: Date(),
            leverage: 2.0
        )

        // Loss of $100 * 2.0 leverage = -$200
        XCTAssertEqual(trade.realizedPnl, -200.0)
    }

    func testFIFOProcessingGeneratesMBGLClosedTrade() throws {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"

        let buySPGI = SpreadsheetIO.BrokerTradeRecord(
            account: "NISA",
            fundName: "SPGI",
            symbol: "SPGI",
            isBuy: true,
            isTransferOut: false,
            isTransferIn: false,
            qty: 16,
            unitPrice: 398.17,
            date: df.date(from: "2020/08/18")
        )

        let xferOutSPGI = SpreadsheetIO.BrokerTradeRecord(
            account: "NISA",
            fundName: "SPGI",
            symbol: "SPGI",
            isBuy: false,
            isTransferOut: true,
            isTransferIn: false,
            qty: 16,
            unitPrice: 0,
            date: df.date(from: "2026/07/01")
        )

        let xferInSPGI = SpreadsheetIO.BrokerTradeRecord(
            account: "一般",
            fundName: "SPGI",
            symbol: "SPGI",
            isBuy: true,
            isTransferOut: false,
            isTransferIn: true,
            qty: 16,
            unitPrice: 0,
            date: df.date(from: "2026/07/01")
        )

        let xferInMBGL = SpreadsheetIO.BrokerTradeRecord(
            account: "一般",
            fundName: "MBGL",
            symbol: "MBGL",
            isBuy: true,
            isTransferOut: false,
            isTransferIn: true,
            qty: 16,
            unitPrice: 0,
            date: df.date(from: "2026/07/01")
        )

        let sellMBGL = SpreadsheetIO.BrokerTradeRecord(
            account: "一般",
            fundName: "MBGL",
            symbol: "MBGL",
            isBuy: false,
            isTransferOut: false,
            isTransferIn: false,
            qty: 16,
            unitPrice: 20.335,
            date: df.date(from: "2026/09/01")
        )

        let portfolios = SpreadsheetIO.processBrokerTradeRecords([
            buySPGI, xferOutSPGI, xferInSPGI, xferInMBGL, sellMBGL
        ])

        let ippan = portfolios.first { $0.name == "一般" }
        XCTAssertNotNil(ippan)

        // SPGI should be in active holdings
        XCTAssertEqual(ippan?.holdings.count, 1)
        XCTAssertEqual(ippan?.holdings.first?.symbol, "SPGI")
        XCTAssertEqual(ippan?.holdings.first?.quantity, 16)
        XCTAssertEqual(ippan?.holdings.first?.avgPrice ?? 0, 398.17 * (1.0 - 0.044), accuracy: 1e-2)

        // MBGL should NOT be in active holdings!
        XCTAssertFalse(ippan?.holdings.contains(where: { $0.symbol == "MBGL" }) ?? true)

        // MBGL SHOULD be in closedTrades!
        XCTAssertEqual(ippan?.closedTrades.count, 1)
        let closedMBGL = ippan?.closedTrades.first
        XCTAssertEqual(closedMBGL?.symbol, "MBGL")
        XCTAssertEqual(closedMBGL?.quantity, 16)
        XCTAssertEqual(closedMBGL?.sellPrice, 20.335)
        XCTAssertEqual(closedMBGL?.buyPrice ?? 0, 398.17 * 0.044, accuracy: 1e-2) // ~$17.52
        XCTAssertGreaterThan(closedMBGL?.realizedPnl ?? 0, 40.0) // ~$45.04 profit!
    }

    @MainActor
    func testStorageServiceRecordSellTrade() {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_storage_\(UUID().uuidString).json")
        let storage = StorageService(fileURL: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let portfolio = storage.createPortfolio(name: "Test Portfolio")

        let holding = Holding(symbol: "NVDA", quantity: 10, avgPrice: 100.0, purchaseDate: Date())
        storage.addHoldingsBatch([holding], to: portfolio.id)

        let p1 = storage.portfolios.first { $0.id == portfolio.id }!
        let activeHoldingId = p1.holdings.first!.id

        // Partial sell: 4 shares @ $150
        storage.recordSellTrade(
            portfolioId: portfolio.id,
            holdingId: activeHoldingId,
            sellQuantity: 4,
            sellPrice: 150.0,
            sellDate: Date()
        )

        let p2 = storage.portfolios.first { $0.id == portfolio.id }!
        XCTAssertEqual(p2.holdings.first?.quantity, 6)
        XCTAssertEqual(p2.closedTrades.count, 1)
        XCTAssertEqual(p2.closedTrades.first?.quantity, 4)
        XCTAssertEqual(p2.closedTrades.first?.realizedPnl, 200.0) // 4 * (150 - 100) = 200

        // Full sell of remaining 6 shares @ $180
        storage.recordSellTrade(
            portfolioId: portfolio.id,
            holdingId: activeHoldingId,
            sellQuantity: 6,
            sellPrice: 180.0,
            sellDate: Date()
        )

        let p3 = storage.portfolios.first { $0.id == portfolio.id }!
        XCTAssertTrue(p3.holdings.isEmpty, "Holding should be removed when quantity reaches 0")
        XCTAssertEqual(p3.closedTrades.count, 2)
        XCTAssertEqual(p3.closedTrades[1].quantity, 6)
        XCTAssertEqual(p3.closedTrades[1].realizedPnl, 480.0) // 6 * (180 - 100) = 480
    }

    func testJapaneseMutualFundScale10000() {
        let trade = ClosedTrade(
            symbol: "42311184",
            quantity: 49841,
            buyPrice: 20064,
            sellPrice: 23454,
            buyDate: Date(),
            sellDate: Date(),
            account: "NISAつみたて投資枠"
        )

        XCTAssertTrue(trade.isJapaneseFund)
        XCTAssertEqual(trade.scale, 10000.0)
        XCTAssertEqual(trade.costBasis, 100_000.9824, accuracy: 1e-2)
        XCTAssertEqual(trade.proceeds, 116_897.0814, accuracy: 1e-2)
        XCTAssertEqual(trade.realizedPnl, 16_896.099, accuracy: 1e-2)
        XCTAssertEqual(trade.realizedPnlPercent, ((23454.0 - 20064.0) / 20064.0) * 100, accuracy: 1e-3)
    }

    func testConsolidatedClosedTrades() {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        let date1 = df.date(from: "2025/08/20")!
        let buyDate1 = df.date(from: "2025/07/01")!
        let buyDate2 = df.date(from: "2025/07/15")!

        let lot1 = ClosedTrade(
            symbol: "1489.T",
            quantity: 10,
            buyPrice: 2500,
            sellPrice: 2800,
            buyDate: buyDate1,
            sellDate: date1,
            account: "特定"
        )
        let lot2 = ClosedTrade(
            symbol: "1489.T",
            quantity: 20,
            buyPrice: 2600,
            sellPrice: 2800,
            buyDate: buyDate2,
            sellDate: date1,
            account: "特定"
        )

        let consolidated = ConsolidatedClosedTrade.consolidate(trades: [lot1, lot2])
        XCTAssertEqual(consolidated.count, 1)

        let c = consolidated[0]
        XCTAssertEqual(c.symbol, "1489.T")
        XCTAssertEqual(c.quantity, 30)
        XCTAssertEqual(c.lots.count, 2)
        // Cost: 10*2500 + 20*2600 = 25000 + 52000 = 77000
        XCTAssertEqual(c.costBasis, 77000)
        // Proceeds: 30*2800 = 84000
        XCTAssertEqual(c.proceeds, 84000)
        // Realized PnL: 84000 - 77000 = 7000
        XCTAssertEqual(c.realizedPnl, 7000)
        // Weighted Buy Price: 77000 / 30 = 2566.666...
        XCTAssertEqual(c.buyPrice, 77000.0 / 30.0, accuracy: 1e-4)
        XCTAssertEqual(c.sellPrice, 2800)
    }

    func testConsolidatedJapaneseFundScale10000() {
        let now = Date()
        let lot1 = ClosedTrade(
            symbol: "42311184",
            quantity: 20000,
            buyPrice: 20000,
            sellPrice: 24000,
            sellDate: now,
            account: "特定"
        )
        let lot2 = ClosedTrade(
            symbol: "42311184",
            quantity: 30000,
            buyPrice: 21000,
            sellPrice: 24000,
            sellDate: now,
            account: "特定"
        )

        let consolidated = ConsolidatedClosedTrade.consolidate(trades: [lot1, lot2])
        XCTAssertEqual(consolidated.count, 1)

        let c = consolidated[0]
        XCTAssertEqual(c.quantity, 50000)
        // Cost basis lot1: 20000 * 20000 / 10000 = 40000
        // Cost basis lot2: 30000 * 21000 / 10000 = 63000
        // Total cost basis = 103000
        XCTAssertEqual(c.costBasis, 103000)
        // Weighted buyPrice: (103000 * 10000) / 50000 = 20600
        XCTAssertEqual(c.buyPrice, 20600)
        // Proceeds: 50000 * 24000 / 10000 = 120000
        XCTAssertEqual(c.proceeds, 120000)
        XCTAssertEqual(c.sellPrice, 24000)
        XCTAssertEqual(c.realizedPnl, 17000)
    }
}

