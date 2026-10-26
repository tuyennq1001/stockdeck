import XCTest
@testable import StockDeck

final class LightweightChartViewSelectionTests: XCTestCase {
    func testToolbarSelectionsAreSharedAcrossSymbolsAndIndependentBetweenCharts() {
        let suite = "LightweightChartViewSelection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        LightweightChartViewSelectionStore.save(.init(range: "1Y", interval: .week),
            surface: .superchart, defaults: defaults)
        LightweightChartViewSelectionStore.save(.init(range: "1M", interval: .hour),
            surface: .detail, defaults: defaults)

        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "AAPL", surface: .superchart, defaults: defaults),
            .init(range: "1Y", interval: .week))
        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "AAPL", surface: .detail, defaults: defaults),
            .init(range: "1M", interval: .hour))
        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "MSFT", surface: .superchart, defaults: defaults),
            .init(range: "1Y", interval: .week))
        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "MSFT", surface: .detail, defaults: defaults),
            .init(range: "1M", interval: .hour))
    }

    func testSavingToolbarSelectionForAnotherSymbolUpdatesTheSharedChartSelection() {
        let suite = "LightweightChartViewSelection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        LightweightChartViewSelectionStore.save(.init(range: "3M", interval: .day),
            surface: .detail, defaults: defaults)
        LightweightChartViewSelectionStore.save(.init(range: "1Y", interval: .week),
            surface: .detail, defaults: defaults)

        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "AAPL", surface: .detail, defaults: defaults),
            .init(range: "1Y", interval: .week))
        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "MSFT", surface: .detail, defaults: defaults),
            .init(range: "1Y", interval: .week))
    }

    func testLegacySuperchartSelectionMigratesToSharedToolbarSelection() {
        let suite = "LightweightChartViewSelection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["range": "6M", "interval": "1D"], forKey: "stockdeck.superchart.view.v1")

        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "AAPL", surface: .superchart, defaults: defaults),
            .init(range: "6M", interval: .day))
        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "MSFT", surface: .superchart, defaults: defaults),
            .init(range: "6M", interval: .day))
    }

    func testPerSymbolSelectionMigratesToSharedToolbarSelection() {
        let suite = "LightweightChartViewSelection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["range": "5Y", "interval": "1M"],
                     forKey: "stockdeck.lightweightChart.view.v2.superchart.AAPL")

        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "AAPL", surface: .superchart, defaults: defaults),
            .init(range: "5Y", interval: .month))
        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "MSFT", surface: .superchart, defaults: defaults),
            .init(range: "5Y", interval: .month))
    }
}
