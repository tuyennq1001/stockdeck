import XCTest
@testable import StockDeck

@MainActor
final class TelegramReportBuilderTests: XCTestCase {

    func testMarketCategoryDetection() {
        let stockService = StockService.shared

        let usCat = TelegramReportBuilder.detectCategory(for: "AAPL", stockService: stockService)
        XCTAssertEqual(usCat, .us)

        let vnCat1 = TelegramReportBuilder.detectCategory(for: "FPT.VN", stockService: stockService)
        XCTAssertEqual(vnCat1, .vn)

        let vnCat2 = TelegramReportBuilder.detectCategory(for: "HPG", exchange: "HOSE", stockService: stockService)
        XCTAssertEqual(vnCat2, .vn)

        let jpCat1 = TelegramReportBuilder.detectCategory(for: "7203.T", stockService: stockService)
        XCTAssertEqual(jpCat1, .jp)

        let jpCat2 = TelegramReportBuilder.detectCategory(for: "0331423B", stockService: stockService) // Rakuten S&P500 fund
        XCTAssertEqual(jpCat2, .jp)

        let cryptoCat1 = TelegramReportBuilder.detectCategory(for: "BTCUSDT", stockService: stockService)
        XCTAssertEqual(cryptoCat1, .crypto)

        let cryptoCat2 = TelegramReportBuilder.detectCategory(for: "ETH-USD", stockService: stockService)
        XCTAssertEqual(cryptoCat2, .crypto)
    }

    func testBuildAllPortfoliosReportAggregatesCorrectly() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = StorageService(fileURL: tempDir.appendingPathComponent("test_data.json"))
        storage.preferredCurrency = "USD"
        storage.appLanguage = "en"

        let stockService = StockService.shared
        stockService.quotes["AAPL"] = StockQuote(
            symbol: "AAPL",
            name: "Apple Inc.",
            price: 200.0,
            change: 4.0,
            changePercent: 2.0,
            regularMarketPreviousClose: 196.0,
            currency: "USD"
        )
        stockService.quotes["BTCUSDT"] = StockQuote(
            symbol: "BTCUSDT",
            name: "Bitcoin",
            price: 60000.0,
            change: 1200.0,
            changePercent: 2.0,
            regularMarketPreviousClose: 58800.0,
            currency: "USD"
        )

        let p1 = Portfolio(id: UUID(), name: "US Equities", holdings: [
            Holding(symbol: "AAPL", quantity: 10, avgPrice: 150) // Value: $2000, Cost: $1500, Day PnL: +$40
        ])
        let p2 = Portfolio(id: UUID(), name: "Crypto", holdings: [
            Holding(symbol: "BTCUSDT", quantity: 0.1, avgPrice: 50000) // Value: $6000, Cost: $5000, Day PnL: +$120
        ])
        storage.portfolios = [p1, p2]

        let report = TelegramReportBuilder.buildAllPortfoliosReport(
            storageService: storage,
            stockService: stockService,
            scheduleLabel: "07:30"
        )

        // Verifications
        XCTAssertTrue(report.contains("ALL PORTFOLIOS SUMMARY (07:30)"))
        XCTAssertTrue(report.contains("Net Worth:"))
        XCTAssertTrue(report.contains("$8,000.00")) // $2000 + $6000
        XCTAssertTrue(report.contains("+$160.00"))   // $40 + $120
        XCTAssertTrue(report.contains("Total Profit:"))
        XCTAssertTrue(report.contains("Unrealized:"))
        XCTAssertTrue(report.contains("Realized:"))
        XCTAssertTrue(report.contains("+$1,500.00")) // ($2000 - $1500) + ($6000 - $5000)
        XCTAssertTrue(report.contains("🇺🇸 US Markets"))
        XCTAssertTrue(report.contains("AAPL"))
        XCTAssertTrue(report.contains("🪙 Crypto"))
        XCTAssertTrue(report.contains("BTCUSDT"))
        XCTAssertTrue(report.contains("StockDeck macOS Briefing"))
    }

    func testBuildAllPortfoliosReportVietnamese() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = StorageService(fileURL: tempDir.appendingPathComponent("test_data_vi.json"))
        storage.preferredCurrency = "USD"
        storage.appLanguage = "vi"

        let stockService = StockService.shared
        stockService.quotes["AAPL"] = StockQuote(
            symbol: "AAPL",
            name: "Apple Inc.",
            price: 200.0,
            change: 4.0,
            changePercent: 2.0,
            regularMarketPreviousClose: 196.0,
            currency: "USD"
        )

        let p1 = Portfolio(id: UUID(), name: "Cổ phiếu Mỹ", holdings: [
            Holding(symbol: "AAPL", quantity: 10, avgPrice: 150)
        ])
        storage.portfolios = [p1]

        let report = TelegramReportBuilder.buildAllPortfoliosReport(
            storageService: storage,
            stockService: stockService,
            scheduleLabel: "07:30"
        )

        XCTAssertTrue(report.contains("TỔNG HỢP TOÀN BỘ DANH MỤC (07:30)"))
        XCTAssertTrue(report.contains("Tổng tài sản:"))
        XCTAssertTrue(report.contains("Hôm nay:"))
        XCTAssertTrue(report.contains("Tổng Lợi Nhuận:"))
        XCTAssertTrue(report.contains("Chưa chốt:"))
        XCTAssertTrue(report.contains("Đã chốt:"))
        XCTAssertTrue(report.contains("🇺🇸 Thị trường Mỹ"))
        XCTAssertTrue(report.contains("Bản tin StockDeck macOS"))
    }

    func testBuildAllPortfoliosReportJapanese() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = StorageService(fileURL: tempDir.appendingPathComponent("test_data_ja.json"))
        storage.preferredCurrency = "USD"
        storage.appLanguage = "ja"

        let stockService = StockService.shared
        stockService.quotes["AAPL"] = StockQuote(
            symbol: "AAPL",
            name: "Apple Inc.",
            price: 200.0,
            change: 4.0,
            changePercent: 2.0,
            regularMarketPreviousClose: 196.0,
            currency: "USD"
        )

        let p1 = Portfolio(id: UUID(), name: "米国株", holdings: [
            Holding(symbol: "AAPL", quantity: 10, avgPrice: 150)
        ])
        storage.portfolios = [p1]

        let report = TelegramReportBuilder.buildAllPortfoliosReport(
            storageService: storage,
            stockService: stockService,
            scheduleLabel: "07:30"
        )

        XCTAssertTrue(report.contains("全ポートフォリオ概要 (07:30)"))
        XCTAssertTrue(report.contains("純資産:"))
        XCTAssertTrue(report.contains("本日:"))
        XCTAssertTrue(report.contains("通算損益:"))
        XCTAssertTrue(report.contains("含み損益:"))
        XCTAssertTrue(report.contains("確定損益:"))
        XCTAssertTrue(report.contains("🇺🇸 米国市場"))
        XCTAssertTrue(report.contains("StockDeck macOS ブリーフィング"))
    }

    func testJapaneseMutualFundNameAndLatestPriceMovement() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = StorageService(fileURL: tempDir.appendingPathComponent("test_data_jp.json"))
        storage.preferredCurrency = "JPY"
        storage.appLanguage = "ja"

        let stockService = StockService.shared
        // 9I31223A is Rakuten Plus S&P500
        stockService.quotes["9I31223A"] = StockQuote(
            symbol: "9I31223A",
            name: "9I31223A",
            price: 12500.0,
            change: 0.0, // NAV hasn't updated today -> 0.0%
            changePercent: 0.0,
            regularMarketPreviousClose: 12500.0,
            currency: "JPY"
        )
        // Historical points to simulate previous day's NAV change
        let d1 = Date().addingTimeInterval(-86400 * 2)
        let d2 = Date().addingTimeInterval(-86400)
        stockService.priceHistory["9I31223A"] = [
            PricePoint(date: d1, close: 12000.0),
            PricePoint(date: d2, close: 12500.0) // +500 JPY (+4.17%)
        ]

        let p1 = Portfolio(id: UUID(), name: "NISA", holdings: [
            Holding(symbol: "9I31223A", quantity: 10000, avgPrice: 10000) // 10000 口 -> Value: 12500 JPY
        ])
        storage.portfolios = [p1]

        let report = TelegramReportBuilder.buildAllPortfoliosReport(
            storageService: storage,
            stockService: stockService
        )

        // Must display readable Japanese fund name instead of raw code
        XCTAssertTrue(report.contains("楽天・プラス・Ｓ＆Ｐ５００インデックス・ファンド"))
        // Must show latest non-zero price move (+4.17%) instead of +0.00%
        XCTAssertTrue(report.contains("+4.17%"))
    }

    func testSortingByPortfolioWeightDescending() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = StorageService(fileURL: tempDir.appendingPathComponent("test_data_sort.json"))
        storage.preferredCurrency = "USD"
        storage.appLanguage = "en"

        let stockService = StockService.shared
        stockService.quotes["SMALL"] = StockQuote(symbol: "SMALL", name: "Small", price: 10, change: 2, changePercent: 20.0, currency: "USD")
        stockService.quotes["BIG"] = StockQuote(symbol: "BIG", name: "Big", price: 1000, change: 1, changePercent: 0.1, currency: "USD")

        let p = Portfolio(id: UUID(), name: "Equities", holdings: [
            Holding(symbol: "SMALL", quantity: 10, avgPrice: 8), // Value: $100
            Holding(symbol: "BIG", quantity: 50, avgPrice: 900)   // Value: $50,000
        ])
        storage.portfolios = [p]

        let report = TelegramReportBuilder.buildAllPortfoliosReport(
            storageService: storage,
            stockService: stockService
        )

        let bigIndex = report.range(of: "BIG")?.lowerBound
        let smallIndex = report.range(of: "SMALL")?.lowerBound
        XCTAssertNotNil(bigIndex)
        XCTAssertNotNil(smallIndex)
        // BIG (largest value) must appear BEFORE SMALL
        XCTAssertTrue(bigIndex! < smallIndex!)
    }

    func testRealizedPnLAndMissingCostAccuracy() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = StorageService(fileURL: tempDir.appendingPathComponent("test_data_realized.json"))
        storage.preferredCurrency = "USD"
        storage.appLanguage = "vi"

        let stockService = StockService.shared
        stockService.quotes["AAPL"] = StockQuote(symbol: "AAPL", name: "Apple", price: 200, change: 0, changePercent: 0, currency: "USD")
        stockService.quotes["CRYPTO"] = StockQuote(symbol: "CRYPTO", name: "Crypto", price: 10000, change: 0, changePercent: 0, currency: "USD")

        // Active holding: AAPL cost 150 -> PnL +50. CRYPTO has NaN avgPrice (missing cost)
        let activeHolding1 = Holding(symbol: "AAPL", quantity: 1, avgPrice: 150)
        let activeHolding2 = Holding(symbol: "CRYPTO", quantity: 1, avgPrice: .nan)

        // Closed trade: MSFT bought 100, sold 130 -> Realized PnL +30
        let closedTrade = ClosedTrade(
            symbol: "MSFT",
            quantity: 1,
            buyPrice: 100,
            sellPrice: 130,
            sellDate: Date()
        )

        var p = Portfolio(id: UUID(), name: "Mixed", holdings: [activeHolding1, activeHolding2])
        p.closedTrades = [closedTrade]
        storage.portfolios = [p]

        let report = TelegramReportBuilder.buildAllPortfoliosReport(
            storageService: storage,
            stockService: stockService
        )

        // Net worth includes AAPL (200) + CRYPTO (10000) = 10,200
        XCTAssertTrue(report.contains("$10,200.00"))
        // Unrealized PnL is ONLY +$50.00 (CRYPTO with missing cost is NOT counted as profit)
        XCTAssertTrue(report.contains("Chưa chốt:"))
        XCTAssertTrue(report.contains("+$50.00"))
        // Realized PnL is +$30.00
        XCTAssertTrue(report.contains("Đã chốt:"))
        XCTAssertTrue(report.contains("+$30.00"))
        // Total Profit is Unrealized ($50) + Realized ($30) = +$80.00
        XCTAssertTrue(report.contains("Tổng Lợi Nhuận:"))
        XCTAssertTrue(report.contains("+$80.00"))
    }

    func testScheduleDescriptionLocalization() {
        XCTAssertEqual(TelegramReportBuilder.scheduleDescription("07:30", lang: "vi"), "Điểm tin sáng (Đóng cửa Mỹ & Crypto)")
        XCTAssertEqual(TelegramReportBuilder.scheduleDescription("15:30", lang: "vi"), "Tổng kết chiều (Đóng cửa VN & Nhật)")
        XCTAssertEqual(TelegramReportBuilder.scheduleDescription("07:30", lang: "ja"), "朝のブリーフィング（米国・暗号資産引け）")
        XCTAssertEqual(TelegramReportBuilder.scheduleDescription("07:30", lang: "en"), "Morning Briefing (US & Crypto close)")
        XCTAssertEqual(TelegramReportBuilder.scheduleDescription("custom", lang: "vi"), "Báo cáo định kỳ")
    }
}
