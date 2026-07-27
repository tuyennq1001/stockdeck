import XCTest
@testable import StockDeck

@MainActor
final class MultiWatchlistTests: XCTestCase {

    func testDefaultWatchlistCreated() {
        let storage = StorageService.shared
        XCTAssertFalse(storage.watchlists.isEmpty)
        XCTAssertNotNil(storage.currentWatchlist)
    }

    func testCreateAndSelectWatchlist() {
        let storage = StorageService.shared
        let countBefore = storage.watchlists.count
        
        let newWl = storage.createWatchlist(name: "Crypto Assets")
        XCTAssertEqual(storage.watchlists.count, countBefore + 1)
        XCTAssertEqual(storage.selectedWatchlistId, newWl.id)
        XCTAssertEqual(storage.currentWatchlist.name, "Crypto Assets")
        XCTAssertTrue(storage.watchlist.isEmpty)
        
        // Add symbol to active watchlist
        storage.addToWatchlist("BTC-USD")
        XCTAssertEqual(storage.watchlist, ["BTC-USD"])
    }

    func testRenameWatchlist() {
        let storage = StorageService.shared
        let wl = storage.createWatchlist(name: "Tech Stocks")
        storage.renameWatchlist(id: wl.id, newName: "FAANG & Tech")
        
        XCTAssertEqual(storage.currentWatchlist.name, "FAANG & Tech")
    }

    func testDeleteWatchlistFallback() {
        let storage = StorageService.shared
        let wl1 = storage.createWatchlist(name: "List 1")
        let wl2 = storage.createWatchlist(name: "List 2")
        
        storage.selectWatchlist(id: wl2.id)
        XCTAssertEqual(storage.currentWatchlist.id, wl2.id)
        
        storage.deleteWatchlist(id: wl2.id)
        XCTAssertEqual(storage.currentWatchlist.id, wl1.id)
    }
}
