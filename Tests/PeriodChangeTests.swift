import XCTest
@testable import StockDeck

final class PeriodChangeTests: XCTestCase {
    func testParsesYahooSparkDictionaryResponse() throws {
        let json = """
        {
          "GOOGL": {
            "symbol": "GOOGL",
            "timestamp": [100, 200, 300],
            "close": [10.0, null, 15.0]
          },
          "ETH-USD": {
            "symbol": "ETH-USD",
            "timestamp": [100, 200],
            "close": [2000.0, 2200.0]
          }
        }
        """

        let histories = try YahooSparkParser.parse(Data(json.utf8))

        XCTAssertEqual(histories["GOOGL"]?.map(\.close), [10, 15])
        XCTAssertEqual(histories["GOOGL"]?.map(\.date.timeIntervalSince1970), [100, 300])
        XCTAssertEqual(histories["ETH-USD"]?.map(\.close), [2000, 2200])
    }

    func testParsesYahooSparkWithDifferentKeyAndSymbol() throws {
        let json = """
        {
          "JPY=X": {
            "symbol": "USDJPY=X",
            "timestamp": [100, 200],
            "close": [150.0, 152.0]
          }
        }
        """

        let histories = try YahooSparkParser.parse(Data(json.utf8))
        XCTAssertEqual(histories["JPY=X"]?.map(\.close), [150.0, 152.0])
        XCTAssertEqual(histories["USDJPY=X"]?.map(\.close), [150.0, 152.0])
    }

    func testUsesLastCloseAtOrBeforeBoundary() throws {
        let boundary = Date(timeIntervalSince1970: 1_000)
        let points = [
            PricePoint(date: Date(timeIntervalSince1970: 800), close: 80),
            PricePoint(date: Date(timeIntervalSince1970: 900), close: 100),
            PricePoint(date: Date(timeIntervalSince1970: 1_100), close: 120),
        ]

        let change = try XCTUnwrap(
            PriceHistory.percentChange(points: points, currentPrice: 125, since: boundary)
        )
        XCTAssertEqual(change, 25, accuracy: 0.0001)
    }

    func testFallsBackToFirstCloseAfterBoundaryForNewListing() throws {
        let boundary = Date(timeIntervalSince1970: 1_000)
        let points = [
            PricePoint(date: Date(timeIntervalSince1970: 1_100), close: 50),
            PricePoint(date: Date(timeIntervalSince1970: 1_200), close: 60),
        ]

        let change = try XCTUnwrap(
            PriceHistory.percentChange(points: points, currentPrice: 75, since: boundary)
        )
        XCTAssertEqual(change, 50, accuracy: 0.0001)
    }

    func testInvalidOrMissingBaselineReturnsNil() {
        XCTAssertNil(PriceHistory.percentChange(points: [], currentPrice: 100, since: Date()))
        XCTAssertNil(PriceHistory.percentChange(
            points: [PricePoint(date: .distantPast, close: 0)],
            currentPrice: 100,
            since: Date()
        ))
    }
}
