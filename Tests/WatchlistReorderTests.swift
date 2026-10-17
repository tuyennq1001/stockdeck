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

    @MainActor
    func testMoveWatchlistTabBeforeAndAfterAndNoOp() {
        let storage = createTestStorage()
        let firstId = storage.watchlists[0].id
        storage.createWatchlist(name: "Crypto")
        storage.createWatchlist(name: "Japan")
        let secondId = storage.watchlists[1].id
        let thirdId = storage.watchlists[2].id

        // Move third before first
        storage.moveWatchlist(from: thirdId, relativeTo: firstId, placement: .before)
        XCTAssertEqual(storage.watchlists.map(\.id), [thirdId, firstId, secondId])

        // Move third after second (to end)
        storage.moveWatchlist(from: thirdId, relativeTo: secondId, placement: .after)
        XCTAssertEqual(storage.watchlists.map(\.id), [firstId, secondId, thirdId])

        // Dropping first before second (already in place) should be a no-op with zero objectWillChange emissions
        var changeCount = 0
        let cancellable = storage.objectWillChange.sink { _ in changeCount += 1 }
        storage.moveWatchlist(from: firstId, relativeTo: secondId, placement: .before)
        XCTAssertEqual(changeCount, 0)
        XCTAssertEqual(storage.watchlists.map(\.id), [firstId, secondId, thirdId])
        _ = cancellable
    }

    @MainActor
    func testMoveWatchlistSymbolsSingleAndGroupAndAtomicSortReset() {
        let storage = createTestStorage()
        storage.watchlist = ["AAPL", "TSLA", "NVDA", "MSFT"]
        let wlId = storage.currentWatchlist.id
        storage.setWatchlistSort(key: WatchlistSortKey.symbol.rawString, ascending: false, for: wlId)

        // Single symbol move from displayed order (e.g. descending symbol order) commits manual order and resets sortKey to .order
        let displayed = ["TSLA", "NVDA", "MSFT", "AAPL"]
        let updated = storage.moveWatchlistSymbols(["AAPL"], relativeTo: "TSLA", placement: .before, in: displayed)
        XCTAssertEqual(updated, ["AAPL", "TSLA", "NVDA", "MSFT"])
        XCTAssertEqual(storage.watchlist, ["AAPL", "TSLA", "NVDA", "MSFT"])
        XCTAssertEqual(storage.currentWatchlist.sortKey, WatchlistSortKey.order.rawString)
        XCTAssertEqual(storage.currentWatchlist.sortAsc, true)

        // Multi-symbol group drag preserves relative order of group members
        let groupResult = storage.moveWatchlistSymbols(["AAPL", "NVDA"], relativeTo: "MSFT", placement: .after)
        XCTAssertEqual(groupResult, ["TSLA", "MSFT", "AAPL", "NVDA"])
        XCTAssertEqual(storage.watchlist, ["TSLA", "MSFT", "AAPL", "NVDA"])

        // No-op drop (moving TSLA before MSFT when already in that slot and sortKey is already .order)
        var changeCount = 0
        let cancellable = storage.objectWillChange.sink { _ in changeCount += 1 }
        let noOpResult = storage.moveWatchlistSymbols(["TSLA"], relativeTo: "MSFT", placement: .before)
        XCTAssertNil(noOpResult)
        XCTAssertEqual(changeCount, 0)
        _ = cancellable
    }
}
