import XCTest
@testable import StockDeck

final class WatchlistReorderTests: XCTestCase {

    @MainActor
    func testMoveWatchlistSymbolBeforeOrAfter() {
        let storage = StorageService.shared
        storage.watchlist = ["AAPL", "TSLA", "NVDA", "MSFT"]

        // Move NVDA before TSLA
        storage.moveWatchlistSymbol("NVDA", beforeOrAfter: "TSLA")
        XCTAssertEqual(storage.watchlist, ["AAPL", "NVDA", "TSLA", "MSFT"])

        // Move AAPL before MSFT
        storage.moveWatchlistSymbol("AAPL", beforeOrAfter: "MSFT")
        XCTAssertEqual(storage.watchlist, ["NVDA", "TSLA", "AAPL", "MSFT"])
    }

    @MainActor
    func testReorderWatchlistFromOffsets() {
        let storage = StorageService.shared
        storage.watchlist = ["AAPL", "TSLA", "NVDA", "MSFT"]

        // Move index 0 ("AAPL") to index 3 (after NVDA)
        storage.reorderWatchlist(fromOffsets: IndexSet(integer: 0), toOffset: 3, currentProjections: storage.watchlist)
        XCTAssertEqual(storage.watchlist, ["TSLA", "NVDA", "AAPL", "MSFT"])
    }
}
