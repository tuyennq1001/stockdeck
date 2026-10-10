import XCTest
import Combine
@testable import StockDeck

final class MarketDataChangeTests: XCTestCase {
    @MainActor
    func testQuoteEventsSeparateRegularAndExtendedChangesAndIgnoreNoOps() {
        let service = StockService.shared
        let symbol = "PERF-EVENT-\(UUID().uuidString)"
        var events: [MarketDataChange] = []
        let token = service.marketDataChanges.sink { events.append($0) }
        defer { token.cancel() }

        var quotes = service.quotes
        quotes[symbol] = StockQuote(symbol: symbol, name: symbol, price: 100, currency: "USD")
        service.quotes = quotes
        XCTAssertTrue(events.contains { $0.kind == .regularQuote })

        var updated = service.quotes
        updated[symbol] = StockQuote(
            symbol: symbol, name: symbol, price: 100, currency: "USD", marketState: "POST",
            postMarketPrice: 101, postMarketChange: 1, postMarketChangePercent: 1
        )
        service.quotes = updated
        XCTAssertEqual(events.suffix(2).map(\.kind), [.regularQuote, .extendedQuote])

        let countAfterChange = events.count
        service.quotes = service.quotes
        XCTAssertEqual(events.count, countAfterChange)
    }
}
