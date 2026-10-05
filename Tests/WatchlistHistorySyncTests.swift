import XCTest
@testable import StockDeck

@MainActor
final class WatchlistHistorySyncTests: XCTestCase {

    private func createTestStorage() -> StorageService {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("test_stockdeck.json")
        return StorageService(fileURL: fileURL)
    }

    func testWatchlistViewModelPrefersFresherPriceHistoryOverStaleWatchlistHistory() async {
        let storage = createTestStorage()
        storage.addToWatchlist("FPT")

        let stockService = StockService.shared
        stockService.quotes["FPT"] = StockQuote(symbol: "FPT", name: "FPT Corp", price: 62100, change: -600, changePercent: -0.96, currency: "VND")

        let cal = Calendar.current
        let now = Date()
        let threeYearsAgo = cal.date(byAdding: .year, value: -3, to: now)!
        let oneYearAgo = cal.date(byAdding: .year, value: -1, to: now)!
        let fortyDaysAgo = cal.date(byAdding: .day, value: -40, to: now)!

        // Stale watchlistHistory (e.g. 40 days old, pre-split baseline 67,281)
        let stalePoints = [
            PricePoint(date: threeYearsAgo, close: 67281),
            PricePoint(date: oneYearAgo, close: 89912),
            PricePoint(date: fortyDaysAgo, close: 72000)
        ]
        stockService.watchlistHistory["FPT"] = stalePoints

        // Fresh priceHistory (up to today, split-adjusted baseline 61,165)
        let freshPoints = [
            PricePoint(date: threeYearsAgo, close: 61165),
            PricePoint(date: oneYearAgo, close: 81739),
            PricePoint(date: fortyDaysAgo, close: 65454),
            PricePoint(date: now, close: 62100)
        ]
        stockService.priceHistory["FPT"] = freshPoints

        let viewModel = WatchlistViewModel()
        viewModel.setup(stockService: stockService, storageService: storage)

        // Wait briefly for the detached task to finish computing
        for _ in 0..<20 {
            if let row = viewModel.rows.first(where: { $0.symbol == "FPT" }), row.threeYearChangePercent != nil {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        guard let row = viewModel.rows.first(where: { $0.symbol == "FPT" }) else {
            XCTFail("FPT row not found in WatchlistViewModel")
            return
        }

        // Expected 3Y change with fresh priceHistory: (62100 - 61165) / 61165 * 100 ≈ +1.53%
        // (Stale watchlistHistory would have yielded -7.70%)
        XCTAssertNotNil(row.threeYearChangePercent)
        if let threeYear = row.threeYearChangePercent {
            XCTAssertEqual(threeYear, 1.53, accuracy: 0.1)
        }

        // Expected 1Y change with fresh priceHistory: (62100 - 81739) / 81739 * 100 ≈ -24.03%
        // (Stale watchlistHistory would have yielded -30.93%)
        XCTAssertNotNil(row.oneYearChangePercent)
        if let oneYear = row.oneYearChangePercent {
            XCTAssertEqual(oneYear, -24.03, accuracy: 0.1)
        }
    }
}
