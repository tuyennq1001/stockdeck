import XCTest
@testable import StockDeck

@MainActor
final class MultiWatchlistTests: XCTestCase {

    private func createTestStorage() -> StorageService {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("test_stockdeck.json")
        return StorageService(fileURL: fileURL)
    }

    func testDefaultWatchlistCreated() {
        let storage = createTestStorage()
        XCTAssertFalse(storage.watchlists.isEmpty)
        XCTAssertNotNil(storage.currentWatchlist)
    }

    func testCreateAndSelectWatchlist() {
        let storage = createTestStorage()
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
        let storage = createTestStorage()
        let wl = storage.createWatchlist(name: "Tech Stocks")
        storage.renameWatchlist(id: wl.id, newName: "FAANG & Tech")
        
        XCTAssertEqual(storage.currentWatchlist.name, "FAANG & Tech")
    }

    func testDeleteWatchlistFallback() {
        let storage = createTestStorage()
        let wl1 = storage.createWatchlist(name: "List 1")
        let wl2 = storage.createWatchlist(name: "List 2")
        
        storage.selectWatchlist(id: wl2.id)
        XCTAssertEqual(storage.currentWatchlist.id, wl2.id)
        
        storage.deleteWatchlist(id: wl2.id)
        XCTAssertEqual(storage.currentWatchlist.id, wl1.id)
    }

    func testSharedWatchlistMetricsUpdate() {
        let storage = createTestStorage()
        let wl1 = storage.createWatchlist(name: "List 1")
        let wl2 = storage.createWatchlist(name: "List 2")

        let newMetrics: [WatchlistMetric] = [.oneMonth, .threeMonths, .ytd, .ath]
        storage.setWatchlistMetrics(newMetrics)

        storage.selectWatchlist(id: wl1.id)
        XCTAssertEqual(storage.watchlistMetrics, newMetrics)

        storage.selectWatchlist(id: wl2.id)
        XCTAssertEqual(storage.watchlistMetrics, newMetrics)
    }

    func testPortfolioChartRangePersistence() {
        let storage = createTestStorage()
        let pId = UUID().uuidString
        XCTAssertNil(storage.chartRange(for: pId))

        storage.setChartRange("3Y", for: pId)
        XCTAssertEqual(storage.chartRange(for: pId), "3Y")

        storage.setChartRange("1Y", for: "all")
        XCTAssertEqual(storage.chartRange(for: "all"), "1Y")
    }

    func testWatchlistSortPersistence() {
        let storage = createTestStorage()
        let wl1 = storage.createWatchlist(name: "List 1")
        let wl2 = storage.createWatchlist(name: "List 2")

        storage.setWatchlistSort(key: "price", ascending: false, for: wl1.id)
        storage.setWatchlistSort(key: "changePercent", ascending: true, for: wl2.id)

        XCTAssertEqual(storage.watchlists.first(where: { $0.id == wl1.id })?.sortKey, "price")
        XCTAssertEqual(storage.watchlists.first(where: { $0.id == wl1.id })?.sortAsc, false)

        XCTAssertEqual(storage.watchlists.first(where: { $0.id == wl2.id })?.sortKey, "changePercent")
        XCTAssertEqual(storage.watchlists.first(where: { $0.id == wl2.id })?.sortAsc, true)
    }

    func testStockChartRangePersistence() {
        let storage = createTestStorage()
        XCTAssertEqual(storage.lastStockChartRange, "1M")

        storage.lastStockChartRange = "3M"
        XCTAssertEqual(storage.lastStockChartRange, "3M")
    }

    func testPortfolioPositionSortPersistence() {
        let storage = createTestStorage()
        let pId = UUID().uuidString

        XCTAssertNil(storage.positionSort(for: pId))

        storage.setPositionSort(column: "pnl", ascending: true, for: pId)
        let sort = storage.positionSort(for: pId)
        XCTAssertNotNil(sort)
        XCTAssertEqual(sort?.column, "pnl")
        XCTAssertEqual(sort?.ascending, true)
    }
}
