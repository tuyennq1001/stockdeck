import XCTest
@testable import StockDeck

@MainActor
final class PortfolioPnlPersistenceTests: XCTestCase {

    private func makeStorage() -> StorageService {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_pnl_\(UUID().uuidString).json")
        return StorageService(fileURL: tempURL)
    }

    func testDailyAndMonthlyPnlRangePerScope() {
        let storage = makeStorage()
        let scopeAll = "all"
        let scope1 = UUID().uuidString
        let scope2 = UUID().uuidString

        // 1. Initial should be nil
        XCTAssertNil(storage.dailyPnlRange(for: scopeAll))
        XCTAssertNil(storage.monthlyPnlRange(for: scopeAll))
        XCTAssertNil(storage.pnlViewMode(for: scopeAll))

        // 2. Set distinct ranges per scope
        storage.setDailyPnlRange("3M", for: scopeAll)
        storage.setMonthlyPnlRange("1Y", for: scopeAll)
        storage.setPnlViewMode("Monthly P&L", for: scopeAll)

        storage.setDailyPnlRange("6M", for: scope1)
        storage.setMonthlyPnlRange("All", for: scope1)
        storage.setPnlViewMode("Daily P&L", for: scope1)

        storage.setDailyPnlRange("1Y", for: scope2)
        storage.setMonthlyPnlRange("3Y", for: scope2)

        // 3. Verify per-scope independence
        XCTAssertEqual(storage.dailyPnlRange(for: scopeAll), "3M")
        XCTAssertEqual(storage.monthlyPnlRange(for: scopeAll), "1Y")
        XCTAssertEqual(storage.pnlViewMode(for: scopeAll), "Monthly P&L")

        XCTAssertEqual(storage.dailyPnlRange(for: scope1), "6M")
        XCTAssertEqual(storage.monthlyPnlRange(for: scope1), "All")
        XCTAssertEqual(storage.pnlViewMode(for: scope1), "Daily P&L")

        XCTAssertEqual(storage.dailyPnlRange(for: scope2), "1Y")
        XCTAssertEqual(storage.monthlyPnlRange(for: scope2), "3Y")
        XCTAssertNil(storage.pnlViewMode(for: scope2))
    }

    func testAppDataExportAndApplyRoundTrip() {
        let storage = makeStorage()
        let scope1 = "portfolio-alpha"
        let scope2 = "portfolio-beta"

        storage.setDailyPnlRange("6M", for: scope1)
        storage.setMonthlyPnlRange("All", for: scope1)
        storage.setPnlViewMode("Daily P&L", for: scope1)

        storage.setDailyPnlRange("3M", for: scope2)
        storage.setMonthlyPnlRange("1Y", for: scope2)
        storage.setPnlViewMode("Monthly P&L", for: scope2)

        let exported = storage.exportAppData()

        XCTAssertEqual(exported.portfolioDailyPnlRanges?[scope1], "6M")
        XCTAssertEqual(exported.portfolioMonthlyPnlRanges?[scope1], "All")
        XCTAssertEqual(exported.portfolioPnlViewModes?[scope1], "Daily P&L")

        XCTAssertEqual(exported.portfolioDailyPnlRanges?[scope2], "3M")
        XCTAssertEqual(exported.portfolioMonthlyPnlRanges?[scope2], "1Y")
        XCTAssertEqual(exported.portfolioPnlViewModes?[scope2], "Monthly P&L")

        // New instance applying exported data
        let storage2 = makeStorage()
        storage2.applyAppData(exported)

        XCTAssertEqual(storage2.dailyPnlRange(for: scope1), "6M")
        XCTAssertEqual(storage2.monthlyPnlRange(for: scope1), "All")
        XCTAssertEqual(storage2.pnlViewMode(for: scope1), "Daily P&L")

        XCTAssertEqual(storage2.dailyPnlRange(for: scope2), "3M")
        XCTAssertEqual(storage2.monthlyPnlRange(for: scope2), "1Y")
        XCTAssertEqual(storage2.pnlViewMode(for: scope2), "Monthly P&L")
    }

    func testClearAllAppDataResetsPnlRanges() {
        let storage = makeStorage()
        let scope = "scope-test"

        storage.setDailyPnlRange("3M", for: scope)
        storage.setMonthlyPnlRange("1Y", for: scope)
        storage.setPnlViewMode("Monthly P&L", for: scope)

        XCTAssertNotNil(storage.dailyPnlRange(for: scope))

        storage.clearAllAppData()

        XCTAssertNil(storage.dailyPnlRange(for: scope))
        XCTAssertNil(storage.monthlyPnlRange(for: scope))
        XCTAssertNil(storage.pnlViewMode(for: scope))
    }
}
