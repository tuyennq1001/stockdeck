import XCTest
@testable import StockDeck

final class SuperchartPortfolioSymbolOrderingTests: XCTestCase {
    func testOrdersByMarketValueDescending() {
        let entries: [SuperchartPortfolioSymbolOrdering.Entry] = [
            .init(symbol: "SMALL", marketValue: 25),
            .init(symbol: "LARGE", marketValue: 200),
            .init(symbol: "MEDIUM", marketValue: 80)
        ]

        XCTAssertEqual(SuperchartPortfolioSymbolOrdering.orderedSymbols(from: entries), ["LARGE", "MEDIUM", "SMALL"])
    }

    func testAggregatesDuplicateSymbolsAndKeepsFirstDisplaySymbol() {
        let entries: [SuperchartPortfolioSymbolOrdering.Entry] = [
            .init(symbol: "aapl", marketValue: 40),
            .init(symbol: "MSFT", marketValue: 70),
            .init(symbol: "AAPL", marketValue: 60)
        ]

        XCTAssertEqual(SuperchartPortfolioSymbolOrdering.orderedSymbols(from: entries), ["aapl", "MSFT"])
    }

    func testUnknownValuesSortLastAndTiesKeepOriginalOrder() {
        let entries: [SuperchartPortfolioSymbolOrdering.Entry] = [
            .init(symbol: "FIRST", marketValue: 50),
            .init(symbol: "SECOND", marketValue: 50),
            .init(symbol: "UNKNOWN", marketValue: nil)
        ]

        XCTAssertEqual(SuperchartPortfolioSymbolOrdering.orderedSymbols(from: entries), ["FIRST", "SECOND", "UNKNOWN"])
    }
}
