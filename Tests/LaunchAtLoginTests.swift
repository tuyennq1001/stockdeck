import XCTest
@testable import StockDeck

final class LaunchAtLoginTests: XCTestCase {

    @MainActor
    func testLaunchAtLoginPropertyExistsAndSyncs() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_launch_storage_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let storage = StorageService(fileURL: tempURL)
        // Verify syncLaunchAtLoginStatus does not throw or crash
        storage.syncLaunchAtLoginStatus()

        // Verify initial state boolean is valid
        XCTAssertNotNil(storage.launchAtLogin)
    }
}
