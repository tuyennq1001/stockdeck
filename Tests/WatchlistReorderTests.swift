import XCTest
@testable import StockDeck

final class WatchlistReorderTests: XCTestCase {

    @MainActor
    private func createTestStorage() -> StorageService {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("test_stockdeck.json")
        return StorageService(fileURL: fileURL)
    }

    @MainActor
    func testMoveWatchlistSymbolBeforeOrAfter() {
        let storage = createTestStorage()
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
        let storage = createTestStorage()
        storage.watchlist = ["AAPL", "TSLA", "NVDA", "MSFT"]

        // Move index 0 ("AAPL") to index 3 (after NVDA)
        storage.reorderWatchlist(fromOffsets: IndexSet(integer: 0), toOffset: 3, currentProjections: storage.watchlist)
        XCTAssertEqual(storage.watchlist, ["TSLA", "NVDA", "AAPL", "MSFT"])
    }
}
