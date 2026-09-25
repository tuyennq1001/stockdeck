import XCTest
@testable import StockDeck

@MainActor
final class SecondaryCurrencyTests: XCTestCase {

    func testDefaultDecimals() {
        XCTAssertEqual(StorageService.defaultDecimals(for: "VND"), 0)
        XCTAssertEqual(StorageService.defaultDecimals(for: "JPY"), 0)
        XCTAssertEqual(StorageService.defaultDecimals(for: "KRW"), 0)
        XCTAssertEqual(StorageService.defaultDecimals(for: "vnd"), 0)
        XCTAssertEqual(StorageService.defaultDecimals(for: "jpy"), 0)

        XCTAssertEqual(StorageService.defaultDecimals(for: "USD"), 2)
        XCTAssertEqual(StorageService.defaultDecimals(for: "EUR"), 2)
        XCTAssertEqual(StorageService.defaultDecimals(for: "GBP"), 2)
        XCTAssertEqual(StorageService.defaultDecimals(for: "CAD"), 2)
        XCTAssertEqual(StorageService.defaultDecimals(for: "AUD"), 2)
        XCTAssertEqual(StorageService.defaultDecimals(for: "CHF"), 2)
    }

    private func createTestStorage() -> StorageService {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("test_stockdeck.json")
        return StorageService(fileURL: fileURL)
    }

    func testSecondaryCurrencyPersistence() {
        let storage = createTestStorage()
        XCTAssertEqual(storage.secondaryCurrency, "")

        storage.secondaryCurrency = "VND"
        let exported = storage.exportAppData()
        XCTAssertEqual(exported.secondaryCurrency, "VND")

        let newStorage = createTestStorage()
        newStorage.applyAppData(exported)
        XCTAssertEqual(newStorage.secondaryCurrency, "VND")

        newStorage.resetToDefaults()
        XCTAssertEqual(newStorage.secondaryCurrency, "")
    }

    func testRateConversion() {
        let stockService = StockService.shared

        // Same currency
        XCTAssertEqual(stockService.rate(from: "USD", to: "USD"), 1.0)
        XCTAssertEqual(stockService.rate(from: "VND", to: "VND"), 1.0)

        // Fallback rate from USD to VND (1 USD ≈ 25,400 VND)
        let usdToVnd = stockService.rate(from: "USD", to: "VND")
        XCTAssertEqual(usdToVnd, 25400.0, accuracy: 0.1)

        // Fallback rate from VND to USD (1 / 25,400)
        let vndToUsd = stockService.rate(from: "VND", to: "USD")
        XCTAssertEqual(vndToUsd, 1.0 / 25400.0, accuracy: 0.000001)

        // Cached live exchange rate test
        stockService.exchangeRates["USDEUR"] = 0.92
        XCTAssertEqual(stockService.rate(from: "USD", to: "EUR"), 0.92, accuracy: 0.0001)
        XCTAssertEqual(stockService.rate(from: "EUR", to: "USD"), 1.0 / 0.92, accuracy: 0.0001)
        stockService.exchangeRates.removeValue(forKey: "USDEUR")
    }

    func testValuationBundleSecondaryCurrencyCalculation() {
        let storage = createTestStorage()
        storage.preferredCurrency = "USD"
        storage.secondaryCurrency = ""

        let vm = PortfolioViewModel(scope: .all)
        vm.setup(stockService: StockService.shared, storageService: storage)
        // With secondaryCurrency disabled (""), secondaryTotalValue should be nil
        XCTAssertNil(vm.secondaryTotalValue)
        XCTAssertNil(vm.secondaryCurrencySymbol)

        // Setting secondaryCurrency to VND
        storage.secondaryCurrency = "VND"
        XCTAssertEqual(vm.secondaryDecimals, 0)

        // Verify formatting with 0 decimals for VND
        let enUS = Locale(identifier: "en_US")
        let formatted = StorageService.formatAmount(1225570000.0, symbol: "₫", decimals: StorageService.defaultDecimals(for: "VND"), locale: enUS)
        XCTAssertEqual(formatted, "₫1,225,570,000")
    }
}
