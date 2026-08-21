import XCTest
@testable import StockDeck

final class CryptoKlinesTests: XCTestCase {

    func testParseBinanceKlinesNormal() {
        let json = """
        [
            [1700000000000, "2000.0", "2100.0", "1950.0", "2050.0", "100.0", 1700086399999],
            [1700086400000, "2050.0", "2200.0", "2040.0", "2180.0", "150.0", 1700172799999]
        ]
        """.data(using: .utf8)!

        let points = StockService.parseBinanceKlines(data: json, invert: false)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].close, 2050.0)
        XCTAssertEqual(points[0].open, 2000.0)
        XCTAssertEqual(points[0].high, 2100.0)
        XCTAssertEqual(points[0].low, 1950.0)

        XCTAssertEqual(points[1].close, 2180.0)
        XCTAssertEqual(points[1].open, 2050.0)
        XCTAssertEqual(points[1].high, 2200.0)
        XCTAssertEqual(points[1].low, 2040.0)
    }

    func testParseBinanceKlinesInverted() {
        // ETHBTC klines (e.g. 0.03125 ETH/BTC) inverted to get BTCETH (32.0 BTC/ETH)
        let json = """
        [
            [1700000000000, "0.040", "0.050", "0.025", "0.03125", "500.0", 1700086399999]
        ]
        """.data(using: .utf8)!

        let points = StockService.parseBinanceKlines(data: json, invert: true)
        XCTAssertEqual(points.count, 1)
        // close = 1 / 0.03125 = 32.0
        XCTAssertEqual(points[0].close, 32.0, accuracy: 0.0001)
        // open = 1 / 0.040 = 25.0
        XCTAssertEqual(points[0].open!, 25.0, accuracy: 0.0001)
        // high = 1 / low = 1 / 0.025 = 40.0
        XCTAssertEqual(points[0].high!, 40.0, accuracy: 0.0001)
        // low = 1 / high = 1 / 0.050 = 20.0
        XCTAssertEqual(points[0].low!, 20.0, accuracy: 0.0001)
    }

    func testPriceHistoryPercentChangeWithCryptoPoints() {
        let calendar = Calendar.current
        let now = Date()
        let oneMonthAgo = calendar.date(byAdding: .month, value: -1, to: now)!
        let twoMonthsAgo = calendar.date(byAdding: .month, value: -2, to: now)!

        let points = [
            PricePoint(date: twoMonthsAgo, close: 1000.0),
            PricePoint(date: oneMonthAgo, close: 2000.0),
            PricePoint(date: now, close: 2400.0)
        ]

        let change1M = PriceHistory.percentChange(points: points, currentPrice: 2400.0, since: oneMonthAgo)
        XCTAssertNotNil(change1M)
        // (2400 - 2000) / 2000 * 100 = 20.0%
        XCTAssertEqual(change1M!, 20.0, accuracy: 0.001)
    }
}
