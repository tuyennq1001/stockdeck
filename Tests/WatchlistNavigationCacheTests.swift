import XCTest
@testable import StockDeck

@MainActor
final class WatchlistNavigationCacheTests: XCTestCase {
    func testReturningToWatchlistRestoresItsRowsBeforeRecomputation() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchlist-navigation-\(UUID().uuidString).json")
        let storage = StorageService(fileURL: fileURL)
        let service = StockService.shared
        let firstSymbol = "NAV-A-\(UUID().uuidString)"
        let secondSymbol = "NAV-B-\(UUID().uuidString)"
        let firstWatchlistID = storage.currentWatchlist.id
        storage.addToWatchlist(firstSymbol)
        service.quotes[firstSymbol] = StockQuote(symbol: firstSymbol, name: "First", price: 10)

        let viewModel = WatchlistViewModel()
        viewModel.setup(stockService: service, storageService: storage)
        await waitUntil { viewModel.rows.contains(where: { $0.symbol == firstSymbol }) }

        viewModel.setActive(false)
        _ = storage.createWatchlist(name: "Second")
        storage.addToWatchlist(secondSymbol)
        service.quotes[secondSymbol] = StockQuote(symbol: secondSymbol, name: "Second", price: 20)
        viewModel.setActive(true)
        XCTAssertFalse(viewModel.rows.contains(where: { $0.symbol == firstSymbol }))
        await waitUntil { viewModel.rows.contains(where: { $0.symbol == secondSymbol }) }

        viewModel.setActive(false)
        storage.selectWatchlist(id: firstWatchlistID)
        viewModel.setActive(true)

        XCTAssertEqual(viewModel.snapshot.scope, firstWatchlistID)
        XCTAssertEqual(viewModel.rows.map(\.symbol), [firstSymbol])

        viewModel.setActive(false)
        service.quotes[firstSymbol] = nil
        service.quotes[secondSymbol] = nil
    }

    func testSelectingCachedWatchlistUsesSnapshotImmediately() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchlist-switch-cache-\(UUID().uuidString).json")
        let storage = StorageService(fileURL: fileURL)
        let service = StockService.shared
        let firstSymbol = "SWITCH-A-\(UUID().uuidString)"
        let secondSymbol = "SWITCH-B-\(UUID().uuidString)"
        let firstWatchlistID = storage.currentWatchlist.id
        storage.addToWatchlist(firstSymbol)
        service.quotes[firstSymbol] = StockQuote(symbol: firstSymbol, name: "First", price: 10)

        let viewModel = WatchlistViewModel()
        viewModel.setup(stockService: service, storageService: storage)
        await waitUntil { !viewModel.snapshot.isLoading && viewModel.rows.contains(where: { $0.symbol == firstSymbol }) }

        let secondWatchlist = storage.createWatchlist(name: "Second")
        storage.addToWatchlist(secondSymbol)
        service.quotes[secondSymbol] = StockQuote(symbol: secondSymbol, name: "Second", price: 20)
        await waitUntil { !viewModel.snapshot.isLoading && viewModel.rows.contains(where: { $0.symbol == secondSymbol }) }

        viewModel.selectWatchlist(id: firstWatchlistID)

        XCTAssertEqual(viewModel.snapshot.scope, firstWatchlistID)
        XCTAssertFalse(viewModel.snapshot.isLoading)
        XCTAssertEqual(viewModel.rows.map(\.symbol), [firstSymbol])

        viewModel.setActive(false)
        service.quotes[firstSymbol] = nil
        service.quotes[secondSymbol] = nil
        storage.deleteWatchlist(id: secondWatchlist.id)
    }

    func testSetupReactivatesPersistentModelWithCachedRowsImmediately() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchlist-tab-cache-\(UUID().uuidString).json")
        let storage = StorageService(fileURL: fileURL)
        let service = StockService.shared
        let symbol = "TAB-CACHE-\(UUID().uuidString)"
        storage.addToWatchlist(symbol)
        service.quotes[symbol] = StockQuote(symbol: symbol, name: "Cached", price: 42)

        let viewModel = WatchlistViewModel()
        viewModel.setup(stockService: service, storageService: storage)
        await waitUntil {
            !viewModel.snapshot.isLoading && viewModel.rows.contains(where: { $0.symbol == symbol })
        }

        viewModel.setActive(false)
        viewModel.setup(stockService: service, storageService: storage)

        XCTAssertFalse(viewModel.snapshot.isLoading)
        XCTAssertEqual(viewModel.rows.map(\.symbol), [symbol])

        viewModel.setActive(false)
        service.quotes[symbol] = nil
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @MainActor () -> Bool
    ) async {
        let start = ContinuousClock.now
        while !condition(), ContinuousClock.now - start < timeout {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the watchlist row snapshot")
    }
}
