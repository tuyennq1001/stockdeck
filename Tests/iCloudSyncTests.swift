import XCTest
@testable import StockDeck

@MainActor
final class iCloudSyncTests: XCTestCase {

    func testSmartMergeWatchlistsCombinesAndDeduplicates() {
        let syncService = iCloudSyncService.shared

        let localWl1 = Watchlist(id: UUID(), name: "US Tech", symbols: ["AAPL", "NVDA"])
        let localWl2 = Watchlist(id: UUID(), name: "Crypto", symbols: ["BTC-USD"])
        let local = StorageService.AppData(
            watchlist: ["AAPL", "NVDA"],
            watchlists: [localWl1, localWl2],
            selectedWatchlistId: localWl1.id,
            portfolioColumns: nil,
            portfolios: [],
            preferredCurrency: "USD"
        )

        let remoteWl1 = Watchlist(id: UUID(), name: "US Tech", symbols: ["NVDA", "MSFT", "GOOG"])
        let remoteWl3 = Watchlist(id: UUID(), name: "Dividend", symbols: ["KO", "JNJ"])
        let remote = StorageService.AppData(
            watchlist: ["NVDA", "MSFT"],
            watchlists: [remoteWl1, remoteWl3],
            selectedWatchlistId: remoteWl1.id,
            portfolioColumns: nil,
            portfolios: [],
            preferredCurrency: "EUR"
        )

        let merged = syncService.smartMerge(local: local, remote: remote)

        XCTAssertEqual(merged.watchlists?.count, 3)

        // US Tech should have AAPL, NVDA, MSFT, GOOG (deduplicated)
        let mergedTech = merged.watchlists?.first { $0.name == "US Tech" }
        XCTAssertNotNil(mergedTech)
        XCTAssertEqual(mergedTech?.symbols, ["AAPL", "NVDA", "MSFT", "GOOG"])

        // Crypto and Dividend should both exist
        XCTAssertTrue(merged.watchlists?.contains { $0.name == "Crypto" } == true)
        XCTAssertTrue(merged.watchlists?.contains { $0.name == "Dividend" } == true)
    }

    func testSmartMergePortfoliosCombinesHoldingsWithoutLosingPositions() {
        let syncService = iCloudSyncService.shared

        let date1 = Date(timeIntervalSince1970: 1_700_000_000)
        let date2 = Date(timeIntervalSince1970: 1_710_000_000)

        let localP1 = Portfolio(id: UUID(), name: "Main", holdings: [
            Holding(symbol: "AAPL", quantity: 10, avgPrice: 150, purchaseDate: date1),
            Holding(symbol: "NVDA", quantity: 5, avgPrice: 400, purchaseDate: date1)
        ])
        let local = StorageService.AppData(
            watchlist: [],
            watchlists: [],
            portfolios: [localP1]
        )

        let remoteP1 = Portfolio(id: UUID(), name: "Main", holdings: [
            Holding(symbol: "AAPL", quantity: 10, avgPrice: 150, purchaseDate: date1), // duplicate
            Holding(symbol: "AAPL", quantity: 5, avgPrice: 160, purchaseDate: date2),  // additional lot
            Holding(symbol: "MSFT", quantity: 8, avgPrice: 300, purchaseDate: date2)   // new holding
        ])
        let remoteP2 = Portfolio(id: UUID(), name: "Retirement", holdings: [
            Holding(symbol: "VOO", quantity: 50, avgPrice: 420)
        ])
        let remote = StorageService.AppData(
            watchlist: [],
            watchlists: [],
            portfolios: [remoteP1, remoteP2]
        )

        let merged = syncService.smartMerge(local: local, remote: remote)

        XCTAssertEqual(merged.portfolios.count, 2)

        let mergedMain = merged.portfolios.first { $0.name == "Main" }
        XCTAssertNotNil(mergedMain)
        // AAPL (10 @ 150), NVDA (5 @ 400), AAPL (5 @ 160), MSFT (8 @ 300) = 4 holdings total
        XCTAssertEqual(mergedMain?.holdings.count, 4)

        let mergedRetirement = merged.portfolios.first { $0.name == "Retirement" }
        XCTAssertNotNil(mergedRetirement)
        XCTAssertEqual(mergedRetirement?.holdings.count, 1)
        XCTAssertEqual(mergedRetirement?.holdings.first?.symbol, "VOO")
    }

    func testExportAndApplyAppDataRoundTrip() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let s = StorageService(fileURL: tempDir.appendingPathComponent("test_sync.json"))

        s.iCloudSyncEnabled = true
        s.preferredCurrency = "JPY"
        s.watchlist = ["AAPL", "TSLA"]

        let exported = s.exportAppData()
        XCTAssertEqual(exported.iCloudSyncEnabled, true)
        XCTAssertEqual(exported.preferredCurrency, "JPY")
        XCTAssertEqual(exported.watchlist, ["AAPL", "TSLA"])

        var modified = exported
        modified.preferredCurrency = "VND"
        let newWl = Watchlist(name: "Watchlist", symbols: ["VIC", "VNM"])
        modified.watchlists = [newWl]
        modified.watchlist = ["VIC", "VNM"]

        s.applyAppData(modified, isFromSync: true)
        XCTAssertEqual(s.preferredCurrency, "VND")
        XCTAssertEqual(s.watchlist, ["VIC", "VNM"])
    }

    func testSmartMergeWithNaNCostBasisHoldingsDoesNotDuplicate() {
        let syncService = iCloudSyncService.shared

        let localP = Portfolio(id: UUID(), name: "Crypto", holdings: [
            Holding(symbol: "BTCUSDT", quantity: 1.5, avgPrice: .nan),
            Holding(symbol: "ETHUSDT", quantity: 10.0, avgPrice: .nan)
        ])
        var currentData = StorageService.AppData(
            watchlist: [],
            watchlists: [],
            portfolios: [localP]
        )

        let remoteP = Portfolio(id: UUID(), name: "Crypto", holdings: [
            Holding(symbol: "BTCUSDT", quantity: 1.5, avgPrice: .nan),
            Holding(symbol: "ETHUSDT", quantity: 10.0, avgPrice: .nan)
        ])
        let remoteData = StorageService.AppData(
            watchlist: [],
            watchlists: [],
            portfolios: [remoteP]
        )

        // Perform smartMerge 5 times in a loop (simulating multiple refresh clicks)
        for _ in 1...5 {
            currentData = syncService.smartMerge(local: currentData, remote: remoteData)
        }

        XCTAssertEqual(currentData.portfolios.count, 1)
        let cryptoP = currentData.portfolios.first
        XCTAssertEqual(cryptoP?.holdings.count, 2)
        XCTAssertEqual(cryptoP?.holdings.first(where: { $0.symbol == "BTCUSDT" })?.quantity, 1.5)
        XCTAssertEqual(cryptoP?.holdings.first(where: { $0.symbol == "ETHUSDT" })?.quantity, 10.0)
    }

    func testSmartMergeReadOnlyPortfolioUsesLatestSnapshot() {
        let syncService = iCloudSyncService.shared

        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_001_000)

        let localP = Portfolio(
            id: UUID(),
            name: "Binance Spot",
            holdings: [Holding(symbol: "BTCUSDT", quantity: 1.0, avgPrice: .nan)],
            sourceType: .binance(keychainId: "test1"),
            lastSyncedAt: t1
        )
        let localData = StorageService.AppData(
            watchlist: [],
            watchlists: [],
            portfolios: [localP]
        )

        let remoteP = Portfolio(
            id: UUID(),
            name: "Binance Spot",
            holdings: [
                Holding(symbol: "BTCUSDT", quantity: 2.5, avgPrice: .nan),
                Holding(symbol: "SOLUSDT", quantity: 50.0, avgPrice: .nan)
            ],
            sourceType: .binance(keychainId: "test1"),
            lastSyncedAt: t2
        )
        let remoteData = StorageService.AppData(
            watchlist: [],
            watchlists: [],
            portfolios: [remoteP]
        )

        let merged = syncService.smartMerge(local: localData, remote: remoteData)
        XCTAssertEqual(merged.portfolios.count, 1)
        let binanceP = merged.portfolios.first
        XCTAssertEqual(binanceP?.holdings.count, 2)
        XCTAssertEqual(binanceP?.holdings.first(where: { $0.symbol == "BTCUSDT" })?.quantity, 2.5)
        XCTAssertEqual(binanceP?.holdings.first(where: { $0.symbol == "SOLUSDT" })?.quantity, 50.0)
        XCTAssertEqual(binanceP?.lastSyncedAt, t2)
    }
}
