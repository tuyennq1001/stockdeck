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
}

