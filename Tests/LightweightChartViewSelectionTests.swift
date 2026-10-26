import XCTest
@testable import StockDeck

final class LightweightChartViewSelectionTests: XCTestCase {
    func testSuperchartRangeAndIntervalAreSharedAcrossSymbols() {
        let suite = "LightweightChartViewSelection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        LightweightChartViewSelectionStore.save(.init(range: "1Y", interval: .week),
            symbol: "AAPL", shared: true, defaults: defaults)

        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "MSFT", shared: true, defaults: defaults),
            .init(range: "1Y", interval: .week))
        XCTAssertEqual(defaults.string(forKey: "stockdeck.superchart.range"), "1Y")
        XCTAssertNil(defaults.dictionary(forKey: "stockdeck.lightweightChart.view.v1.AAPL"))
    }

    func testDetailChartSelectionsRemainPerSymbol() {
        let suite = "LightweightChartViewSelection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        LightweightChartViewSelectionStore.save(.init(range: "3M", interval: .day),
            symbol: "AAPL", shared: false, defaults: defaults)
        LightweightChartViewSelectionStore.save(.init(range: "1Y", interval: .week),
            symbol: "MSFT", shared: false, defaults: defaults)

        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "AAPL", shared: false, defaults: defaults),
            .init(range: "3M", interval: .day))
        XCTAssertEqual(LightweightChartViewSelectionStore.load(symbol: "MSFT", shared: false, defaults: defaults),
            .init(range: "1Y", interval: .week))
    }
}
