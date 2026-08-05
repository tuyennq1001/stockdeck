import XCTest
@testable import StockDeck

@MainActor
final class PortfolioDeletionTests: XCTestCase {
    var storageService: StorageService!

    override func setUp() async throws {
        try await super.setUp()
        storageService = StorageService()
    }

    override func tearDown() async throws {
        storageService = nil
        try await super.tearDown()
    }

    func testRemoveSingleHoldingSuccess() {
        let pId = UUID()
        let h1 = Holding(symbol: "AAPL", quantity: 10, avgPrice: 150)
        let h2 = Holding(symbol: "MSFT", quantity: 5, avgPrice: 300)
        let portfolio = Portfolio(id: pId, name: "Test Portfolio", holdings: [h1, h2])
        storageService.portfolios = [portfolio]

        XCTAssertEqual(storageService.portfolios[0].holdings.count, 2)

        storageService.removeHolding(from: pId, holdingId: h1.id)

        XCTAssertEqual(storageService.portfolios[0].holdings.count, 1)
        XCTAssertEqual(storageService.portfolios[0].holdings.first?.symbol, "MSFT")
    }

    func testRemoveHoldingFromReadOnlyPortfolioIgnored() {
        let pId = UUID()
        let h1 = Holding(symbol: "BTC-USD", quantity: 1, avgPrice: 50000)
        let portfolio = Portfolio(id: pId, name: "Binance ReadOnly", holdings: [h1], sourceType: .binance(keychainId: "key1"))
        storageService.portfolios = [portfolio]

        XCTAssertTrue(storageService.portfolios[0].isReadOnly)

        storageService.removeHolding(from: pId, holdingId: h1.id)

        XCTAssertEqual(storageService.portfolios[0].holdings.count, 1, "Holding in read-only portfolio must not be removed")
    }

    func testRemoveSymbolRemovesAllLotsForSymbol() {
        let pId = UUID()
        let h1 = Holding(symbol: "AAPL", quantity: 10, avgPrice: 150)
        let h2 = Holding(symbol: "AAPL", quantity: 20, avgPrice: 160)
        let h3 = Holding(symbol: "NVDA", quantity: 5, avgPrice: 120)
        let portfolio = Portfolio(id: pId, name: "Multi Lot", holdings: [h1, h2, h3])
        storageService.portfolios = [portfolio]

        XCTAssertEqual(storageService.portfolios[0].holdings.count, 3)

        storageService.removeSymbol(from: pId, symbol: "aapl")

        XCTAssertEqual(storageService.portfolios[0].holdings.count, 1)
        XCTAssertEqual(storageService.portfolios[0].holdings.first?.symbol, "NVDA")
    }

    func testMoveSymbolTransfersAllLotsToTargetPortfolio() {
        let sourceId = UUID()
        let targetId = UUID()
        let h1 = Holding(symbol: "AAPL", quantity: 10, avgPrice: 150)
        let h2 = Holding(symbol: "AAPL", quantity: 20, avgPrice: 160)
        let h3 = Holding(symbol: "NVDA", quantity: 5, avgPrice: 120)

        let p1 = Portfolio(id: sourceId, name: "Source Port", holdings: [h1, h2, h3])
        let p2 = Portfolio(id: targetId, name: "Target Port", holdings: [])
        storageService.portfolios = [p1, p2]

        storageService.moveSymbol(symbol: "AAPL", from: sourceId, to: targetId)

        let updatedP1 = storageService.portfolios.first(where: { $0.id == sourceId })
        let updatedP2 = storageService.portfolios.first(where: { $0.id == targetId })

        XCTAssertEqual(updatedP1?.holdings.count, 1)
        XCTAssertEqual(updatedP1?.holdings.first?.symbol, "NVDA")

        XCTAssertEqual(updatedP2?.holdings.count, 2)
        XCTAssertEqual(updatedP2?.holdings[0].symbol, "AAPL")
        XCTAssertEqual(updatedP2?.holdings[1].symbol, "AAPL")
    }

    func testMoveSymbolToReadOnlyPortfolioIgnored() {
        let sourceId = UUID()
        let targetId = UUID()
        let h1 = Holding(symbol: "TSLA", quantity: 5, avgPrice: 200)

        let p1 = Portfolio(id: sourceId, name: "Source Port", holdings: [h1])
        let p2 = Portfolio(id: targetId, name: "Binance ReadOnly", holdings: [], sourceType: .binance(keychainId: "key2"))
        storageService.portfolios = [p1, p2]

        storageService.moveSymbol(symbol: "TSLA", from: sourceId, to: targetId)

        let updatedP1 = storageService.portfolios.first(where: { $0.id == sourceId })
        let updatedP2 = storageService.portfolios.first(where: { $0.id == targetId })

        XCTAssertEqual(updatedP1?.holdings.count, 1)
        XCTAssertEqual(updatedP2?.holdings.count, 0)
    }
}
