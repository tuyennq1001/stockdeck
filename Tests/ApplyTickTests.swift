import XCTest
@testable import StockDeck

/// Reproduces the field-reuse bug in `StockService.applyTick`: a PRE/POST-market
/// WebSocket tick was overwriting the *regular*-session price, so a user with
/// extended hours turned off saw the moving pre/post price where they expected
/// the last regular close.
@MainActor
final class ApplyTickTests: XCTestCase {

    private func makeTicker(id: String, price: Float, marketHours: MarketHoursType) -> Yaticker {
        var t = Yaticker()
        t.id = id
        t.price = price
        t.marketHours = marketHours
        t.currency = "USD"
        return t
    }

    override func tearDown() {
        StockService.shared.quotes.removeValue(forKey: "TSTX")
        super.tearDown()
    }

    /// A PRE-market tick must not clobber the regular price; it only updates the
    /// pre-market fields.
    func testPreMarketTickDoesNotClobberRegularPrice() {
        StockService.shared.quotes["TSTX"] = StockQuote(
            symbol: "TSTX", name: "Test", price: 100, change: 1, changePercent: 1,
            currency: "USD", marketState: "REGULAR", dayHigh: nil, dayLow: nil,
            fiftyTwoWeekHigh: nil, fiftyTwoWeekLow: nil,
            preMarketPrice: nil, preMarketChange: nil, preMarketChangePercent: nil,
            postMarketPrice: nil, postMarketChange: nil, postMarketChangePercent: nil)

        _ = StockService.shared.applyTick(makeTicker(id: "TSTX", price: 105, marketHours: .preMarket))

        let q = StockService.shared.quotes["TSTX"]!
        XCTAssertEqual(q.price, 100, "regular price must be preserved during pre-market")
        XCTAssertEqual(q.preMarketPrice, 105, "pre-market price should reflect the tick")
        XCTAssertEqual(q.displayPrice(extendedHours: false), 100, "extended-off shows last regular close")
        XCTAssertEqual(q.displayPrice(extendedHours: true), 105, "extended-on shows live pre-market")
    }

    /// A POST-market tick behaves the same for the regular price.
    func testPostMarketTickDoesNotClobberRegularPrice() {
        StockService.shared.quotes["TSTX"] = StockQuote(
            symbol: "TSTX", name: "Test", price: 100, change: 1, changePercent: 1,
            currency: "USD", marketState: "REGULAR", dayHigh: nil, dayLow: nil,
            fiftyTwoWeekHigh: nil, fiftyTwoWeekLow: nil,
            preMarketPrice: nil, preMarketChange: nil, preMarketChangePercent: nil,
            postMarketPrice: nil, postMarketChange: nil, postMarketChangePercent: nil)

        _ = StockService.shared.applyTick(makeTicker(id: "TSTX", price: 98, marketHours: .postMarket))

        let q = StockService.shared.quotes["TSTX"]!
        XCTAssertEqual(q.price, 100)
        XCTAssertEqual(q.postMarketPrice, 98)
        XCTAssertEqual(q.displayPrice(extendedHours: false), 100)
    }

    /// A REGULAR tick updates the regular price as before.
    func testRegularTickUpdatesRegularPrice() {
        _ = StockService.shared.applyTick(makeTicker(id: "TSTX", price: 200, marketHours: .regularMarket))
        XCTAssertEqual(StockService.shared.quotes["TSTX"]?.price, 200)
    }

    /// Ticks for Vietnamese stocks (e.g. ACB matching Aurora Cannabis on Yahoo) must be ignored.
    func testVietnameseTickIsIgnoredAndDoesNotClobberQuote() {
        StockService.shared.quotes["ACB"] = StockQuote(
            symbol: "ACB",
            name: "Ngân hàng Á Châu (ACB)",
            price: 20450,
            change: 0,
            changePercent: 0,
            currency: "VND",
            marketState: "CLOSED"
        )
        defer { StockService.shared.quotes.removeValue(forKey: "ACB") }

        let changed = StockService.shared.applyTick(makeTicker(id: "ACB", price: 4.25, marketHours: .regularMarket))
        XCTAssertFalse(changed, "Tick for Vietnamese stock must be dropped")
        XCTAssertEqual(StockService.shared.quotes["ACB"]?.price, 20450, "ACB price must not be clobbered by Yahoo 4.25 tick")
    }

    /// Ticks for Japanese mutual funds must be ignored.
    func testJapaneseMutualFundTickIsIgnored() {
        let fundCode = "0331418A"
        StockService.shared.quotes[fundCode] = StockQuote(
            symbol: fundCode,
            name: "eMAXIS Slim",
            price: 25000,
            change: 0,
            changePercent: 0,
            currency: "JPY",
            marketState: "CLOSED"
        )
        defer { StockService.shared.quotes.removeValue(forKey: fundCode) }

        let changed = StockService.shared.applyTick(makeTicker(id: fundCode, price: 120, marketHours: .regularMarket))
        XCTAssertFalse(changed, "Tick for Japanese mutual fund must be dropped")
        XCTAssertEqual(StockService.shared.quotes[fundCode]?.price, 25000)
    }

    /// Verify collectWebSocketSymbols excludes Vietnamese stocks, Japanese mutual funds, and crypto.
    func testCollectWebSocketSymbolsExcludesVietnameseStocksAndJapaneseFunds() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = StorageService(fileURL: tempDir.appendingPathComponent("test_storage.json"))

        storage.watchlists = [
            Watchlist(name: "Test", symbols: ["AAPL", "ACB", "VIC", "0331418A", "BTC-USD"])
        ]

        let wsSymbols = StockService.collectWebSocketSymbols(storageService: storage)
        XCTAssertTrue(wsSymbols.contains("AAPL"), "US stock AAPL should be included")
        XCTAssertFalse(wsSymbols.contains("ACB"), "Vietnamese stock ACB must NOT be included in Yahoo WebSocket")
        XCTAssertFalse(wsSymbols.contains("VIC"), "Vietnamese stock VIC must NOT be included in Yahoo WebSocket")
        XCTAssertFalse(wsSymbols.contains("0331418A"), "Japanese mutual fund must NOT be included in Yahoo WebSocket")
        XCTAssertFalse(wsSymbols.contains("BTC-USD"), "Crypto must NOT be included in Yahoo WebSocket")
    }
}
