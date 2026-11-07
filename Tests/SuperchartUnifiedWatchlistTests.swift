import XCTest
@testable import StockDeck

final class SuperchartUnifiedWatchlistTests: XCTestCase {

    func testLightweightChartAlertLineModel() {
        let line = LightweightChartAlertLine(price: 150.0, title: "🔔 ≥ 150.00", color: "#e67e22")
        XCTAssertEqual(line.price, 150.0)
        XCTAssertEqual(line.title, "🔔 ≥ 150.00")
        XCTAssertEqual(line.color, "#e67e22")

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(line) else {
            XCTFail("Failed to encode LightweightChartAlertLine")
            return
        }
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(LightweightChartAlertLine.self, from: data) else {
            XCTFail("Failed to decode LightweightChartAlertLine")
            return
        }
        XCTAssertEqual(decoded, line)
    }

    func testSuperchartDetailTabs() {
        let tabs = SuperchartDetailTab.allCases
        XCTAssertEqual(tabs.count, 3)
        XCTAssertEqual(tabs[0], .overview)
        XCTAssertEqual(tabs[1], .news)
        XCTAssertEqual(tabs[2], .notes)
        XCTAssertEqual(tabs[0].rawValue, "Tổng quan")
        XCTAssertEqual(tabs[1].rawValue, "Tin tức")
        XCTAssertEqual(tabs[2].rawValue, "Ghi chú")
    }

    func testWatchlistViewModeValues() {
        let modes = WatchlistWideView.ViewMode.allCases
        XCTAssertEqual(modes.count, 2)
        XCTAssertEqual(modes[0].rawValue, "table")
        XCTAssertEqual(modes[1].rawValue, "chart")
    }

    func testSuperchartSubViewModes() {
        let modes = SuperchartSubViewMode.allCases
        XCTAssertEqual(modes.count, 2)
        XCTAssertEqual(modes[0], .chart)
        XCTAssertEqual(modes[1], .table)
        XCTAssertEqual(modes[0].rawValue, "Biểu đồ")
        XCTAssertEqual(modes[1].rawValue, "Bảng chi tiết")
    }

    func testSymbolDeepDiveCategories() {
        let categories = SymbolDeepDiveView.Category.allCases
        XCTAssertEqual(categories.count, 9)
        XCTAssertEqual(categories[0].rawValue, "Tất cả")
        XCTAssertEqual(categories[1].rawValue, "Định giá")
        XCTAssertEqual(categories[2].rawValue, "Sinh lời & Rủi ro")
        XCTAssertEqual(categories[3].rawValue, "Hiệu suất & Alpha")
        XCTAssertEqual(categories[4].rawValue, "Đỉnh/Đáy & Mục tiêu")
        XCTAssertEqual(categories[5].rawValue, "Earnings")
        XCTAssertEqual(categories[6].rawValue, "Giao dịch nội bộ")
        XCTAssertEqual(categories[7].rawValue, "Tin tức")
        XCTAssertEqual(categories[8].rawValue, "Ghi chú")
    }

    func testMetricPeriodsAndTooltips() {
        let periods = MetricPeriod.allCases
        XCTAssertEqual(periods.count, 10)
        XCTAssertEqual(periods.map(\.rawValue), ["Today", "1M", "3M", "6M", "YTD", "1Y", "2Y", "3Y", "5Y", "10Y"])
        for p in periods {
            XCTAssertFalse(p.tooltip.isEmpty, "Tooltip for \(p.rawValue) should not be empty")
        }
    }

    func testSymbolPerformanceMetricsValues() {
        let metrics = SymbolPerformanceMetrics(
            symbol: "AAPL",
            price: 220.0,
            today: 1.5,
            oneMonth: 3.2,
            threeMonths: -2.1,
            sixMonths: 10.4,
            ytd: 15.6,
            oneYear: 25.0,
            twoYears: 40.0,
            threeYears: 60.0,
            fiveYears: 120.0,
            tenYears: 300.0,
            ath: 235.0,
            atl: 50.0,
            fromAth: -6.38,
            fromAtl: 340.0
        )

        XCTAssertEqual(metrics.value(for: .today), 1.5)
        XCTAssertEqual(metrics.value(for: .oneMonth), 3.2)
        XCTAssertEqual(metrics.value(for: .ytd), 15.6)
        XCTAssertEqual(metrics.value(for: .tenYears), 300.0)
        XCTAssertEqual(metrics.fromAth, -6.38)
    }

    func testBenchmarkSymbolForDifferentMarkets() {
        // Vietnamese stocks → VN-Index
        let vn1 = StockService.benchmarkSymbol(for: "ACB")
        XCTAssertEqual(vn1.symbol, "^VNINDEX.VN")
        XCTAssertEqual(vn1.name, "VN-Index")

        let vn2 = StockService.benchmarkSymbol(for: "HPG.HM")
        XCTAssertEqual(vn2.symbol, "^VNINDEX.VN")
        XCTAssertEqual(vn2.name, "VN-Index")

        let vn3 = StockService.benchmarkSymbol(for: "VCB.VN")
        XCTAssertEqual(vn3.symbol, "^VNINDEX.VN")
        XCTAssertEqual(vn3.name, "VN-Index")

        // Japanese stocks & funds → Nikkei 225
        let jp1 = StockService.benchmarkSymbol(for: "7203.T")
        XCTAssertEqual(jp1.symbol, "^N225")
        XCTAssertEqual(jp1.name, "Nikkei 225")

        let jp2 = StockService.benchmarkSymbol(for: "03311187") // eMAXIS Slim
        XCTAssertEqual(jp2.symbol, "^N225")
        XCTAssertEqual(jp2.name, "Nikkei 225")

        // US & global stocks → S&P 500
        let us1 = StockService.benchmarkSymbol(for: "AAPL")
        XCTAssertEqual(us1.symbol, "^GSPC")
        XCTAssertEqual(us1.name, "S&P 500")

        let us2 = StockService.benchmarkSymbol(for: "MSFT")
        XCTAssertEqual(us2.symbol, "^GSPC")
        XCTAssertEqual(us2.name, "S&P 500")

        // Indices themselves compared to S&P 500
        let idxVN = StockService.benchmarkSymbol(for: "^VNINDEX.VN")
        XCTAssertEqual(idxVN.symbol, "^GSPC")
        XCTAssertEqual(idxVN.name, "S&P 500")

        let idxN225 = StockService.benchmarkSymbol(for: "^N225")
        XCTAssertEqual(idxN225.symbol, "^GSPC")
        XCTAssertEqual(idxN225.name, "S&P 500")
    }

    func testVietnameseNewsSmartParameters() {
        let params = StockService.smartNewsParameters(symbol: "ACB", displayName: "Ngân hàng Á Châu")
        XCTAssertEqual(params.region, "VN")
        XCTAssertEqual(params.language, "vi")
        XCTAssertEqual(params.ceid, "VN:vi")
        XCTAssertTrue(params.query.contains("ACB"))
    }
}
