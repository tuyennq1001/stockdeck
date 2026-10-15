import XCTest
@testable import StockDeck

final class AppEnvironmentTests: XCTestCase {

    func testAppEnvironmentDevProperties() {
        if AppEnvironment.isDev {
            XCTAssertEqual(AppEnvironment.appSupportFolderName, "StockDeck-Dev")
            XCTAssertEqual(AppEnvironment.iCloudFolderName, "StockDeck-Dev")
            XCTAssertEqual(AppEnvironment.keychainServiceName, "com.stockdeck.app.binance.dev")
        } else {
            XCTAssertEqual(AppEnvironment.appSupportFolderName, "StockDeck")
            XCTAssertEqual(AppEnvironment.iCloudFolderName, "StockDeck")
            XCTAssertEqual(AppEnvironment.keychainServiceName, "com.stockdeck.app.binance")
        }
    }

    func testAppEnvironmentDirectories() {
        let activeURL = AppEnvironment.appSupportDirectoryURL
        let prodURL = AppEnvironment.prodAppSupportDirectoryURL

        XCTAssertEqual(activeURL.lastPathComponent, AppEnvironment.appSupportFolderName)
        XCTAssertEqual(prodURL.lastPathComponent, "StockDeck")
    }

    func testAutoSeedDevDataWhenFilesDoNotExist() {
        // Test that autoSeedDevDataIfNeeded runs safely without throwing or crashing
        AppEnvironment.autoSeedDevDataIfNeeded()
    }

    func testCloneDirectoryCopiesDataAndCaches() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("AppEnvTest-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let destDir = tempRoot.appendingPathComponent("Dest", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let sampleData = "{\"watchlists\":[{\"name\":\"Tech\",\"symbols\":[\"AAPL\"]}],\"portfolios\":[]}".data(using: .utf8)!
        try sampleData.write(to: sourceDir.appendingPathComponent("data.json"))

        let sampleCache = "{\"AAPL\":[{\"close\":150.0}]}".data(using: .utf8)!
        try sampleCache.write(to: sourceDir.appendingPathComponent("historyCache.json"))

        let logoDir = sourceDir.appendingPathComponent("Logos", isDirectory: true)
        try FileManager.default.createDirectory(at: logoDir, withIntermediateDirectories: true)
        try "dummy-logo".data(using: .utf8)!.write(to: logoDir.appendingPathComponent("AAPL.png"))

        let success = try AppEnvironment.cloneDirectory(from: sourceDir, to: destDir)
        XCTAssertTrue(success)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("data.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("historyCache.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("Logos/AAPL.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent(".dev_seeded").path))

        let copiedData = try Data(contentsOf: destDir.appendingPathComponent("data.json"))
        XCTAssertEqual(copiedData, sampleData)
    }

    func testIsDevDataEffectivelyEmpty() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EmptyCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let emptyURL = tempDir.appendingPathComponent("empty.json")
        let emptyJSON = "{\"watchlists\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Watchlist\",\"symbols\":[]}],\"portfolios\":[]}"
        try emptyJSON.data(using: .utf8)!.write(to: emptyURL)
        XCTAssertTrue(AppEnvironment.isDevDataEffectivelyEmpty(emptyURL))

        let nonEmptyWatchlistURL = tempDir.appendingPathComponent("non_empty_wl.json")
        let nonEmptyWatchlistJSON = "{\"watchlists\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Watchlist\",\"symbols\":[\"AAPL\"]}],\"portfolios\":[]}"
        try nonEmptyWatchlistJSON.data(using: .utf8)!.write(to: nonEmptyWatchlistURL)
        XCTAssertFalse(AppEnvironment.isDevDataEffectivelyEmpty(nonEmptyWatchlistURL))

        let nonEmptyPortfolioURL = tempDir.appendingPathComponent("non_empty_pf.json")
        let nonEmptyPortfolioJSON = "{\"watchlists\":[],\"portfolios\":[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"name\":\"Main\",\"holdings\":[{\"symbol\":\"NVDA\"}]}]}"
        try nonEmptyPortfolioJSON.data(using: .utf8)!.write(to: nonEmptyPortfolioURL)
        XCTAssertFalse(AppEnvironment.isDevDataEffectivelyEmpty(nonEmptyPortfolioURL))

        let missingURL = tempDir.appendingPathComponent("does_not_exist.json")
        XCTAssertTrue(AppEnvironment.isDevDataEffectivelyEmpty(missingURL))
    }
}
