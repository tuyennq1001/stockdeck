import XCTest
@testable import StockDeck

final class StockTargetTests: XCTestCase {

    @MainActor
    private func createIsolatedStorage() -> StorageService {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return StorageService(fileURL: tempDir.appendingPathComponent("test_stockdeck.json"))
    }

    func testStockTargetDistanceAndBuyZone() {
        let target = StockTarget(symbol: "AAPL", targetPrice: 200.0)

        // Case 1: Current price is higher (waiting for dip)
        // (200 - 220) / 220 * 100 = -9.0909%
        let distWaiting = target.percentDistance(from: 220.0)
        XCTAssertNotNil(distWaiting)
        XCTAssertEqual(distWaiting!, -9.0909, accuracy: 0.001)
        XCTAssertFalse(target.isInBuyZone(currentPrice: 220.0))

        // Case 2: Current price equals target price (exactly at target)
        let distExact = target.percentDistance(from: 200.0)
        XCTAssertNotNil(distExact)
        XCTAssertEqual(distExact!, 0.0, accuracy: 0.001)
        XCTAssertTrue(target.isInBuyZone(currentPrice: 200.0))

        // Case 3: Current price has dropped below target (in buy zone)
        // (200 - 180) / 180 * 100 = +11.1111%
        let distBelow = target.percentDistance(from: 180.0)
        XCTAssertNotNil(distBelow)
        XCTAssertEqual(distBelow!, 11.1111, accuracy: 0.001)
        XCTAssertTrue(target.isInBuyZone(currentPrice: 180.0))

        // Case 4: Invalid current price <= 0
        XCTAssertNil(target.percentDistance(from: 0.0))
        XCTAssertNil(target.percentDistance(from: -10.0))
        XCTAssertFalse(target.isInBuyZone(currentPrice: 0.0))
    }

    @MainActor
    func testStorageServiceBuyTargetCRUD() {
        let storage = createIsolatedStorage()

        XCTAssertNil(storage.buyTarget(for: "NVDA"))

        // Create
        storage.setBuyTarget(symbol: "NVDA", targetPrice: 110.0, note: "Key support level", notifyWhenReached: true)
        let target = storage.buyTarget(for: "NVDA")
        XCTAssertNotNil(target)
        XCTAssertEqual(target?.symbol, "NVDA")
        XCTAssertEqual(target?.targetPrice, 110.0)
        XCTAssertEqual(target?.note, "Key support level")
        XCTAssertTrue(target?.notifyWhenReached == true)
        XCTAssertFalse(target?.isReached == true)

        // Update
        storage.setBuyTarget(symbol: "NVDA", targetPrice: 115.0, note: "Adjusted target", notifyWhenReached: false)
        let updated = storage.buyTarget(for: "NVDA")
        XCTAssertEqual(updated?.targetPrice, 115.0)
        XCTAssertEqual(updated?.note, "Adjusted target")
        XCTAssertFalse(updated?.notifyWhenReached == true)

        // Mark Reached
        storage.markTargetReached(symbol: "NVDA")
        XCTAssertTrue(storage.buyTarget(for: "NVDA")?.isReached == true)
        XCTAssertNotNil(storage.buyTarget(for: "NVDA")?.reachedAt)

        // Delete
        storage.removeBuyTarget(for: "NVDA")
        XCTAssertNil(storage.buyTarget(for: "NVDA"))
    }

    @MainActor
    func testStorageServiceBatchTargetOperations() {
        let storage = createIsolatedStorage()
        storage.setBuyTarget(symbol: "AAPL", targetPrice: 200, notifyWhenReached: true)
        storage.setBuyTarget(symbol: "MSFT", targetPrice: 400, notifyWhenReached: true)

        XCTAssertTrue(storage.buyTarget(for: "AAPL")?.notifyWhenReached == true)
        storage.setBuyTargetNotify(symbol: "AAPL", notify: false)
        XCTAssertFalse(storage.buyTarget(for: "AAPL")?.notifyWhenReached == true)

        storage.removeBuyTargets(symbols: ["AAPL", "MSFT"])
        XCTAssertNil(storage.buyTarget(for: "AAPL"))
        XCTAssertNil(storage.buyTarget(for: "MSFT"))
    }

    func testSortWatchlistByBuyTarget() {
        // AAPL price: 220, target: 200 (distance: -9.09%)
        // MSFT price: 400, target: 395 (distance: -1.25%, closer)
        // GOOG price: 150, target: 160 (distance: +6.67%, in buy zone)
        // TSLA has NO target
        let qAAPL = StockQuote(symbol: "AAPL", name: "Apple", price: 220, change: 0, changePercent: 0, currency: "USD")
        let qMSFT = StockQuote(symbol: "MSFT", name: "Microsoft", price: 400, change: 0, changePercent: 0, currency: "USD")
        let qGOOG = StockQuote(symbol: "GOOG", name: "Google", price: 150, change: 0, changePercent: 0, currency: "USD")
        let qTSLA = StockQuote(symbol: "TSLA", name: "Tesla", price: 250, change: 0, changePercent: 0, currency: "USD")

        let quotes = ["AAPL": qAAPL, "MSFT": qMSFT, "GOOG": qGOOG, "TSLA": qTSLA]
        let targets = [
            "AAPL": StockTarget(symbol: "AAPL", targetPrice: 200),
            "MSFT": StockTarget(symbol: "MSFT", targetPrice: 395),
            "GOOG": StockTarget(symbol: "GOOG", targetPrice: 160)
        ]

        let symbols = ["AAPL", "MSFT", "GOOG", "TSLA"]

        // Ascending sort: lowest percentDistance first
        // AAPL (-9.09%) < MSFT (-1.25%) < GOOG (+6.67%) < TSLA (no target at the end)
        let sortedAsc = StorageService.sortWatchlistSymbols(
            symbols,
            key: .metric(.buyTarget),
            ascending: true,
            quotes: quotes,
            stockTargets: targets
        )
        XCTAssertEqual(sortedAsc, ["AAPL", "MSFT", "GOOG", "TSLA"])

        // Descending sort: highest percentDistance first (in zone / closest first)
        let sortedDesc = StorageService.sortWatchlistSymbols(
            symbols,
            key: .metric(.buyTarget),
            ascending: false,
            quotes: quotes,
            stockTargets: targets
        )
        XCTAssertEqual(sortedDesc, ["GOOG", "MSFT", "AAPL", "TSLA"])
    }

    @MainActor
    func testAlertMonitorFiresForBuyTarget() {
        let storage = createIsolatedStorage()
        storage.setBuyTarget(symbol: "AMD", targetPrice: 150.0, note: "Dip buy", notifyWhenReached: true)

        let monitor = AlertMonitor(storage: storage)

        // Case 1: Price is above target -> Should not trigger
        let highQuote = StockQuote(symbol: "AMD", name: "AMD", price: 160.0, change: 0, changePercent: 0, currency: "USD")
        monitor.check(quotes: ["AMD": highQuote])
        XCTAssertFalse(storage.buyTarget(for: "AMD")?.isReached == true)

        // Case 2: Price hits target -> Should trigger and mark isReached = true
        let lowQuote = StockQuote(symbol: "AMD", name: "AMD", price: 148.0, change: -12, changePercent: -7.5, currency: "USD")
        monitor.check(quotes: ["AMD": lowQuote])
        XCTAssertTrue(storage.buyTarget(for: "AMD")?.isReached == true)
        XCTAssertNotNil(storage.buyTarget(for: "AMD")?.reachedAt)
    }

    func testTargetMetricInWatchlistMetric() {
        XCTAssertEqual(WatchlistMetric.buyTarget.rawValue, "buyTarget")
        XCTAssertEqual(WatchlistMetric.buyTarget.title, "Buy Target")
        XCTAssertEqual(WatchlistMetric.buyTarget.category, .price)
        XCTAssertFalse(WatchlistMetric.buyTarget.isChart)

        let sortKey = WatchlistSortKey.from(rawString: "metric:buyTarget")
        XCTAssertEqual(sortKey, .metric(.buyTarget))
    }
}
