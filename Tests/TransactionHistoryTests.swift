import XCTest
@testable import StockDeck

@MainActor
final class TransactionHistoryTests: XCTestCase {

    func testTransactionJSONSerialization() throws {
        let now = Date()
        let tx = Transaction(
            id: UUID(),
            date: now,
            symbol: "AAPL",
            type: .buy,
            quantity: 10,
            price: 150.50,
            amount: 1505.00,
            currency: "USD",
            account: "NISA",
            notes: "Test buy note"
        )

        let encoded = try JSONEncoder().encode(tx)
        let decoded = try JSONDecoder().decode(Transaction.self, from: encoded)

        XCTAssertEqual(decoded.id, tx.id)
        XCTAssertEqual(decoded.symbol, "AAPL")
        XCTAssertEqual(decoded.type, .buy)
        XCTAssertEqual(decoded.quantity, 10)
        XCTAssertEqual(decoded.price, 150.50)
        XCTAssertEqual(decoded.amount, 1505.00)
        XCTAssertEqual(decoded.account, "NISA")
        XCTAssertEqual(decoded.notes, "Test buy note")
    }

    func testTransactionDeduplicationSignature() {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        let date1 = df.date(from: "2026/09/01")!
        let date2 = df.date(from: "2026/09/01")!

        let tx1 = Transaction(date: date1, symbol: "MBGL", type: .sell, quantity: 16, price: 20.335, account: "一般")
        let tx2 = Transaction(date: date2, symbol: "MBGL", type: .sell, quantity: 16, price: 20.335, account: "一般")

        XCTAssertEqual(tx1.signature, tx2.signature)
    }

    func testStorageServiceTransactionManagement() {
        let storage = StorageService()
        let p = storage.createPortfolio(name: "Ledger Test Portfolio")

        let now = Date()
        let tx1 = Transaction(date: now, symbol: "SPGI", type: .buy, quantity: 16, price: 398.17, account: "NISA")
        let tx2 = Transaction(date: now, symbol: "MBGL", type: .sell, quantity: 16, price: 20.335, account: "一般")

        storage.addTransactionsBatch([tx1, tx2], to: p.id)

        let targetP = storage.portfolios.first { $0.id == p.id }
        XCTAssertEqual(targetP?.transactions.count, 2)

        // Adding duplicate should not increase count
        storage.addTransactionsBatch([tx1], to: p.id)
        let afterDupe = storage.portfolios.first { $0.id == p.id }
        XCTAssertEqual(afterDupe?.transactions.count, 2)

        // Remove transaction
        storage.removeTransaction(from: p.id, transactionId: tx1.id)
        let afterRemove = storage.portfolios.first { $0.id == p.id }
        XCTAssertEqual(afterRemove?.transactions.count, 1)
        XCTAssertEqual(afterRemove?.transactions.first?.symbol, "MBGL")
    }

    func testBrokerTradeRecordsGeneratesTransactions() {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"

        let buySPGI = SpreadsheetIO.BrokerTradeRecord(
            account: "NISA",
            fundName: "",
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
            fundName: "",
            symbol: "SPGI",
            isBuy: false,
            isTransferOut: true,
            isTransferIn: false,
            qty: 16,
            unitPrice: 0.0,
            date: df.date(from: "2026/07/01")
        )

        let xferInSPGI = SpreadsheetIO.BrokerTradeRecord(
            account: "一般",
            fundName: "",
            symbol: "SPGI",
            isBuy: true,
            isTransferOut: false,
            isTransferIn: true,
            qty: 16,
            unitPrice: 0.0,
            date: df.date(from: "2026/07/01")
        )

        let sellMBGL = SpreadsheetIO.BrokerTradeRecord(
            account: "一般",
            fundName: "",
            symbol: "MBGL",
            isBuy: false,
            isTransferOut: false,
            isTransferIn: false,
            qty: 16,
            unitPrice: 20.335,
            date: df.date(from: "2026/09/01")
        )

        let portfolios = SpreadsheetIO.processBrokerTradeRecords([
            buySPGI, xferOutSPGI, xferInSPGI, sellMBGL
        ])

        let nisa = portfolios.first { $0.name == "NISA" }
        XCTAssertNotNil(nisa)
        let nisaTxs = nisa?.transactions ?? []
        XCTAssertEqual(nisaTxs.count, 2)
        let hasNisaBuy = nisaTxs.contains { $0.type == .buy && $0.symbol == "SPGI" }
        let hasNisaXferOut = nisaTxs.contains { $0.type == .transferOut && $0.symbol == "SPGI" }
        XCTAssertTrue(hasNisaBuy)
        XCTAssertTrue(hasNisaXferOut)

        let ippan = portfolios.first { $0.name == "一般" }
        XCTAssertNotNil(ippan)
        let ippanTxs = ippan?.transactions ?? []
        XCTAssertEqual(ippanTxs.count, 2)
        let hasIppanXferIn = ippanTxs.contains { $0.type == .transferIn && $0.symbol == "SPGI" }
        let hasIppanSell = ippanTxs.contains { $0.type == .sell && $0.symbol == "MBGL" }
        XCTAssertTrue(hasIppanXferIn)
        XCTAssertTrue(hasIppanSell)
    }

    func testConsolidatedTransactions() {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        let date1 = df.date(from: "2025/08/20")!

        let fill1 = Transaction(
            date: date1,
            symbol: "1489.T",
            type: .buy,
            quantity: 10,
            price: 2500,
            account: "特定"
        )
        let fill2 = Transaction(
            date: date1,
            symbol: "1489.T",
            type: .buy,
            quantity: 20,
            price: 2560,
            account: "特定"
        )

        let consolidated = ConsolidatedTransaction.consolidate(transactions: [fill1, fill2])
        XCTAssertEqual(consolidated.count, 1)

        let c = consolidated[0]
        XCTAssertEqual(c.symbol, "1489.T")
        XCTAssertEqual(c.type, .buy)
        XCTAssertEqual(c.quantity, 30)
        XCTAssertEqual(c.transactions.count, 2)
        // Amount: 10*2500 + 20*2560 = 25000 + 51200 = 76200
        XCTAssertEqual(c.effectiveAmount, 76200)
        // Weighted price: 76200 / 30 = 2540
        XCTAssertEqual(c.price, 2540)
    }

    func testConsolidatedTransactionsJapaneseFundScale10000() {
        let now = Date()
        let fill1 = Transaction(
            date: now,
            symbol: "42311184",
            type: .buy,
            quantity: 20000,
            price: 20000,
            account: "特定"
        )
        let fill2 = Transaction(
            date: now,
            symbol: "42311184",
            type: .buy,
            quantity: 30000,
            price: 21000,
            account: "特定"
        )

        let consolidated = ConsolidatedTransaction.consolidate(transactions: [fill1, fill2])
        XCTAssertEqual(consolidated.count, 1)

        let c = consolidated[0]
        XCTAssertEqual(c.quantity, 50000)
        // Amount fill1: 20000 * 20000 / 10000 = 40000
        // Amount fill2: 30000 * 21000 / 10000 = 63000
        // Total effectiveAmount: 103000
        XCTAssertEqual(c.effectiveAmount, 103000)
        // Weighted price: (103000 * 10000) / 50000 = 20600
        XCTAssertEqual(c.price, 20600)
    }

    func testStorageServiceAddHoldingRecordsBuyTransaction() {
        let storage = StorageService()
        let p = storage.createPortfolio(name: "Manual Add Test")
        XCTAssertTrue(p.transactions.isEmpty)

        let purchaseDate = Date()
        storage.addHolding(to: p.id, symbol: "AAPL", quantity: 10, avgPrice: 150.0, purchaseDate: purchaseDate)

        let targetP = storage.portfolios.first { $0.id == p.id }
        XCTAssertEqual(targetP?.holdings.count, 1)
        XCTAssertEqual(targetP?.transactions.count, 1)

        let tx = targetP?.transactions.first
        XCTAssertEqual(tx?.symbol, "AAPL")
        XCTAssertEqual(tx?.type, .buy)
        XCTAssertEqual(tx?.quantity, 10)
        XCTAssertEqual(tx?.price, 150.0)
        XCTAssertEqual(tx?.amount, 1500.0)
    }

    func testReconstructTransactionsFromClosedTradesAndHoldings() {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        let buyDate = df.date(from: "2024/01/15")!
        let sellDate = df.date(from: "2024/06/20")!

        let closed = ClosedTrade(
            symbol: "9434.T",
            quantity: 100,
            buyPrice: 1200.0,
            sellPrice: 1500.0,
            buyDate: buyDate,
            sellDate: sellDate,
            account: "特定"
        )

        let holdingDate = df.date(from: "2024/03/10")!
        let holding = Holding(
            symbol: "VOO",
            quantity: 5,
            avgPrice: 450.0,
            purchaseDate: holdingDate,
            account: "NISA成長投資枠"
        )

        let reconstructed = StorageService.reconstructTransactions(
            fromClosedTrades: [closed],
            holdings: [holding]
        )

        // 1 buy for closed + 1 sell for closed + 1 buy for holding = 3
        XCTAssertEqual(reconstructed.count, 3)

        // Check newest first
        XCTAssertEqual(reconstructed[0].symbol, "9434.T")
        XCTAssertEqual(reconstructed[0].type, .sell)
        XCTAssertEqual(reconstructed[0].quantity, 100)
        XCTAssertEqual(reconstructed[0].price, 1500.0)
        XCTAssertEqual(reconstructed[0].date, sellDate)

        XCTAssertEqual(reconstructed[1].symbol, "VOO")
        XCTAssertEqual(reconstructed[1].type, .buy)
        XCTAssertEqual(reconstructed[1].quantity, 5)
        XCTAssertEqual(reconstructed[1].price, 450.0)
        XCTAssertEqual(reconstructed[1].date, holdingDate)

        XCTAssertEqual(reconstructed[2].symbol, "9434.T")
        XCTAssertEqual(reconstructed[2].type, .buy)
        XCTAssertEqual(reconstructed[2].quantity, 100)
        XCTAssertEqual(reconstructed[2].price, 1200.0)
        XCTAssertEqual(reconstructed[2].date, buyDate)
    }

    func testMigrateEmptyTransactionsIfNeeded() {
        let storage = StorageService()
        let p = storage.createPortfolio(name: "Migration Test")
        // Manually simulate a portfolio with holdings and closed trades but 0 transactions
        guard let pIndex = storage.portfolios.firstIndex(where: { $0.id == p.id }) else {
            XCTFail("Portfolio not found")
            return
        }

        storage.portfolios[pIndex].holdings = [
            Holding(symbol: "AAPL", quantity: 10, avgPrice: 150.0)
        ]
        storage.portfolios[pIndex].closedTrades = [
            ClosedTrade(symbol: "MSFT", quantity: 5, buyPrice: 300.0, sellPrice: 350.0, buyDate: Date(), sellDate: Date())
        ]
        storage.portfolios[pIndex].transactions = []

        let didMigrate = storage.migrateEmptyTransactionsIfNeeded()
        XCTAssertTrue(didMigrate)

        let targetP = storage.portfolios.first { $0.id == p.id }
        XCTAssertEqual(targetP?.transactions.count, 3) // 1 holding buy + 1 closed buy + 1 closed sell

        // Second call should return false since transactions are no longer empty
        let didMigrateAgain = storage.migrateEmptyTransactionsIfNeeded()
        XCTAssertFalse(didMigrateAgain)
    }

    func testBrokerFilesImportStatusReturnsTransactions() throws {
        let csvContent = """
        約定日,受渡日,ティッカー,銘柄名,口座,取引区分,売買区分,信用区分,弁済期限,決済通貨,数量［株］,単価［USドル］,約定代金［USドル］,為替レート,手数料［USドル］,税金［USドル］,受渡金額［USドル］,受渡金額［円］
        "2026/8/18","2026/8/20","SPGI","S&P GLOBAL","一般","現物","買付","-","-","米ドル","16","398.1700","6370.72","150.00","0.00","0.00","6370.72","-"
        """
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("broker_test_\(UUID().uuidString).csv")
        try csvContent.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let status = PortfolioIO.parseBrokerFilesStatus(urls: [tempURL])
        switch status {
        case .success(let result):
            XCTAssertEqual(result.items.count, 1)
            XCTAssertEqual(result.transactions.count, 1)
            let tx = result.transactions.first
            XCTAssertEqual(tx?.symbol, "SPGI")
            XCTAssertEqual(tx?.type, .buy)
            XCTAssertEqual(tx?.quantity, 16)
        default:
            XCTFail("Expected .success with transactions, got \(status)")
        }
    }
}

