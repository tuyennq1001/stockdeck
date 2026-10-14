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
}
