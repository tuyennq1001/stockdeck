import XCTest
@testable import StockDeck

final class WatchlistSortSyncTests: XCTestCase {

    func testWatchlistSortKeyParsing() {
        XCTAssertEqual(WatchlistSortKey.from(rawString: nil), .order)
        XCTAssertEqual(WatchlistSortKey.from(rawString: "order"), .order)
        XCTAssertEqual(WatchlistSortKey.from(rawString: "manual"), .order)
        XCTAssertEqual(WatchlistSortKey.from(rawString: "symbol"), .symbol)
        XCTAssertEqual(WatchlistSortKey.from(rawString: "price"), .price)
        XCTAssertEqual(WatchlistSortKey.from(rawString: "metric:price"), .price)
        XCTAssertEqual(WatchlistSortKey.from(rawString: "changePercent"), .changePercent)
        XCTAssertEqual(WatchlistSortKey.from(rawString: "metric:today"), .changePercent)
        XCTAssertEqual(WatchlistSortKey.from(rawString: "extChangePercent"), .extChangePercent)
        XCTAssertEqual(WatchlistSortKey.from(rawString: "metric:ext"), .extChangePercent)
        XCTAssertEqual(WatchlistSortKey.from(rawString: "absoluteChange"), .metric(.todayChange))
        XCTAssertEqual(WatchlistSortKey.from(rawString: "metric:todayChange"), .metric(.todayChange))
        XCTAssertEqual(WatchlistSortKey.from(rawString: "metric:oneMonth"), .metric(.oneMonth))
        XCTAssertEqual(WatchlistSortKey.from(rawString: "metric:ath"), .metric(.ath))
        XCTAssertEqual(WatchlistSortKey.from(rawString: "unknown_key"), .order)
    }

    func testSortWatchlistSymbolsOrder() {
        let symbols = ["AAPL", "NVDA", "MSFT"]
        let asc = StorageService.sortWatchlistSymbols(symbols, key: .order, ascending: true, quotes: [:])
        XCTAssertEqual(asc, ["AAPL", "NVDA", "MSFT"])

        let desc = StorageService.sortWatchlistSymbols(symbols, key: .order, ascending: false, quotes: [:])
        XCTAssertEqual(desc, ["MSFT", "NVDA", "AAPL"])
    }

    func testSortWatchlistSymbolsAlphabetical() {
        let symbols = ["NVDA", "AAPL", "MSFT"]
        let asc = StorageService.sortWatchlistSymbols(symbols, key: .symbol, ascending: true, quotes: [:])
        XCTAssertEqual(asc, ["AAPL", "MSFT", "NVDA"])

        let desc = StorageService.sortWatchlistSymbols(symbols, key: .symbol, ascending: false, quotes: [:])
        XCTAssertEqual(desc, ["NVDA", "MSFT", "AAPL"])
    }

    func testSortWatchlistSymbolsPriceWithFX() {
        // AAPL: 200 USD (rate 1.0 -> 200)
        // VNM: 70,000 VND (rate 0.00004 -> 2.8 USD)
        // 7203.T: 3000 JPY (rate 0.0067 -> 20.1 USD)
        let qAAPL = StockQuote(symbol: "AAPL", name: "Apple", price: 200, change: 2, changePercent: 1.0, currency: "USD")
        let qVNM = StockQuote(symbol: "VNM", name: "Vinamilk", price: 70000, change: 500, changePercent: 0.7, currency: "VND")
        let q7203 = StockQuote(symbol: "7203.T", name: "Toyota", price: 3000, change: 10, changePercent: 0.3, currency: "JPY")

        let quotes = ["AAPL": qAAPL, "VNM": qVNM, "7203.T": q7203]
        let rates: [String: Double] = ["USD": 1.0, "VND": 0.00004, "JPY": 0.0067]

        let symbols = ["AAPL", "VNM", "7203.T"]
        let asc = StorageService.sortWatchlistSymbols(
            symbols,
            key: .price,
            ascending: true,
            quotes: quotes,
            priceRate: { rates[$0] ?? 1.0 }
        )
        // Ascending prices in USD: VNM (2.8) < 7203.T (20.1) < AAPL (200)
        XCTAssertEqual(asc, ["VNM", "7203.T", "AAPL"])

        let desc = StorageService.sortWatchlistSymbols(
            symbols,
            key: .price,
            ascending: false,
            quotes: quotes,
            priceRate: { rates[$0] ?? 1.0 }
        )
        XCTAssertEqual(desc, ["AAPL", "7203.T", "VNM"])
    }

    func testSortWatchlistSymbolsChangePercent() {
        let q1 = StockQuote(symbol: "AAPL", name: "Apple", price: 150, change: 3, changePercent: 2.0)
        let q2 = StockQuote(symbol: "NVDA", name: "Nvidia", price: 120, change: -6, changePercent: -5.0)
        let q3 = StockQuote(symbol: "MSFT", name: "Microsoft", price: 400, change: 40, changePercent: 10.0)

        let quotes = ["AAPL": q1, "NVDA": q2, "MSFT": q3]
        let symbols = ["AAPL", "NVDA", "MSFT"]

        let asc = StorageService.sortWatchlistSymbols(symbols, key: .changePercent, ascending: true, quotes: quotes)
        XCTAssertEqual(asc, ["NVDA", "AAPL", "MSFT"])

        let desc = StorageService.sortWatchlistSymbols(symbols, key: .changePercent, ascending: false, quotes: quotes)
        XCTAssertEqual(desc, ["MSFT", "AAPL", "NVDA"])
    }

    func testSortWatchlistSymbolsMissingQuotesSinkToBottom() {
        let q1 = StockQuote(symbol: "AAPL", name: "Apple", price: 150, change: 3, changePercent: 2.0)
        let quotes = ["AAPL": q1]
        let symbols = ["MISSING1", "AAPL", "MISSING2"]

        let asc = StorageService.sortWatchlistSymbols(symbols, key: .price, ascending: true, quotes: quotes)
        XCTAssertEqual(asc, ["AAPL", "MISSING1", "MISSING2"])

        let desc = StorageService.sortWatchlistSymbols(symbols, key: .price, ascending: false, quotes: quotes)
        XCTAssertEqual(desc, ["AAPL", "MISSING1", "MISSING2"])
    }
}
