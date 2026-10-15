import XCTest
@testable import StockDeck

/// Regression tests for Yahoo v7 batch-quote parsing.
///
/// Bug: `V7Quote.regularMarketPrice` used to be non-optional, so a single
/// delisted/suspended ticker in the batch (which comes back without a price)
/// made the whole `JSONDecoder` call throw — dropping *every* symbol's live
/// quote and forcing a slow per-symbol fallback. Parsing must now skip the
/// bad entry and keep the good ones.
final class V7QuoteParsingTests: XCTestCase {

    private func json(_ s: String) -> Data { s.data(using: .utf8)! }

    func testValidBatchParsesAllSymbols() throws {
        let data = json("""
        {"quoteResponse": {"result": [
          {"symbol": "AAPL", "regularMarketPrice": 200.0, "regularMarketPreviousClose": 190.0, "currency": "USD", "marketState": "REGULAR", "quoteType": "EQUITY"},
          {"symbol": "MSFT", "regularMarketPrice": 400.0, "currency": "USD", "marketState": "REGULAR"}
        ], "error": null}}
        """)
        let result = try StockService.parseV7Response(data)
        XCTAssertEqual(result.quotes.count, 2)
        XCTAssertEqual(Set(result.quotes.map { $0.symbol }), ["AAPL", "MSFT"])
        XCTAssertEqual(result.types["AAPL"], "EQUITY")
    }

    func testPartialQuoteWithoutPriceIsSkippedNotFatal() throws {
        // Middle entry has no regularMarketPrice — must not nuke the whole batch.
        let data = json("""
        {"quoteResponse": {"result": [
          {"symbol": "AAPL", "regularMarketPrice": 200.0, "currency": "USD", "marketState": "REGULAR"},
          {"symbol": "DEAD", "currency": "USD", "marketState": "CLOSED"},
          {"symbol": "MSFT", "regularMarketPrice": 400.0, "currency": "USD", "marketState": "REGULAR"}
        ], "error": null}}
        """)
        let result = try StockService.parseV7Response(data)
        XCTAssertEqual(result.quotes.count, 2, "the two priced symbols should still parse")
        XCTAssertEqual(Set(result.quotes.map { $0.symbol }), ["AAPL", "MSFT"])
        XCTAssertFalse(result.quotes.contains { $0.symbol == "DEAD" })
    }

    func testDerivedChangeAndPercent() throws {
        let data = json("""
        {"quoteResponse": {"result": [
          {"symbol": "AAPL", "regularMarketPrice": 110.0, "regularMarketPreviousClose": 100.0, "currency": "USD", "marketState": "REGULAR"}
        ], "error": null}}
        """)
        let q = try XCTUnwrap(try StockService.parseV7Response(data).quotes.first)
        XCTAssertEqual(q.change, 10.0, accuracy: 0.0001)
        XCTAssertEqual(q.changePercent, 10.0, accuracy: 0.0001)
        XCTAssertEqual(q.previousClose, 100.0, accuracy: 0.0001)
    }

    func testEmptyResultYieldsNoQuotes() throws {
        let data = json(#"{"quoteResponse": {"result": [], "error": null}}"#)
        XCTAssertTrue(try StockService.parseV7Response(data).quotes.isEmpty)
    }

    func testParsesValuationMetricsWhenPresent() throws {
        let data = json("""
        {"quoteResponse": {"result": [
          {
            "symbol": "AAPL",
            "regularMarketPrice": 220.0,
            "currency": "USD",
            "marketState": "REGULAR",
            "trailingPE": 33.5,
            "forwardPE": 28.2,
            "priceToBook": 45.1,
            "bookValue": 4.88,
            "epsTrailingTwelveMonths": 6.57,
            "epsForward": 7.80,
            "dividendYield": 0.55,
            "marketCap": 3400000000000.0
          }
        ], "error": null}}
        """)
        let result = try StockService.parseV7Response(data)
        let q = try XCTUnwrap(result.quotes.first)
        XCTAssertEqual(q.trailingPE, 33.5)
        XCTAssertEqual(q.forwardPE, 28.2)
        XCTAssertEqual(q.priceToBook, 45.1)
        XCTAssertEqual(q.bookValue, 4.88)
        XCTAssertEqual(q.epsTrailingTwelveMonths, 6.57)
        XCTAssertEqual(q.epsForward, 7.80)
        XCTAssertEqual(q.dividendYield, 0.55)
        XCTAssertEqual(q.marketCap, 3400000000000.0)
        XCTAssertTrue(q.hasValuationData)
    }

    func testParsesTrailingAnnualDividendYieldFallback() throws {
        let data = json("""
        {"quoteResponse": {"result": [
          {
            "symbol": "MSFT",
            "regularMarketPrice": 420.0,
            "currency": "USD",
            "marketState": "REGULAR",
            "trailingAnnualDividendYield": 0.0075
          }
        ], "error": null}}
        """)
        let result = try StockService.parseV7Response(data)
        let q = try XCTUnwrap(result.quotes.first)
        let dy = try XCTUnwrap(q.dividendYield)
        XCTAssertEqual(dy, 0.75, accuracy: 0.0001)
        XCTAssertTrue(q.hasValuationData)
    }

    func testMissingValuationMetricsDefaultToNilAndHasValuationDataIsFalse() throws {
        let data = json("""
        {"quoteResponse": {"result": [
          {"symbol": "^GSPC", "regularMarketPrice": 5800.0, "currency": "USD", "marketState": "REGULAR"}
        ], "error": null}}
        """)
        let result = try StockService.parseV7Response(data)
        let q = try XCTUnwrap(result.quotes.first)
        XCTAssertNil(q.trailingPE)
        XCTAssertNil(q.forwardPE)
        XCTAssertNil(q.priceToBook)
        XCTAssertNil(q.bookValue)
        XCTAssertNil(q.epsTrailingTwelveMonths)
        XCTAssertNil(q.epsForward)
        XCTAssertNil(q.dividendYield)
        XCTAssertFalse(q.hasValuationData)
    }
}
