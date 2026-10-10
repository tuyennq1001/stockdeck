import XCTest
@testable import StockDeck

final class PortfolioBackfillCacheTests: XCTestCase {
    func testHistoryCorrectionWithSameCountAndEndpointsInvalidatesCache() {
        let holding = Holding(symbol: "CACHE-TEST", quantity: 1, avgPrice: 100)
        let firstDay = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = [firstDay, firstDay.addingTimeInterval(86_400), firstDay.addingTimeInterval(172_800)]
        let original = [100.0, 110.0, 100.0].enumerated().map { index, close in
            PricePoint(date: dates[index], close: close)
        }
        let corrected = [100.0, 120.0, 100.0].enumerated().map { index, close in
            PricePoint(date: dates[index], close: close)
        }

        let originalSeries = PortfolioBackfill.series(
            holdings: [holding], historyBySymbol: [holding.symbol: original], rateBySymbol: [holding.symbol: 1]
        )
        let correctedSeries = PortfolioBackfill.series(
            holdings: [holding], historyBySymbol: [holding.symbol: corrected], rateBySymbol: [holding.symbol: 1]
        )

        XCTAssertEqual(originalSeries.count, correctedSeries.count)
        XCTAssertEqual(originalSeries.first?.value, correctedSeries.first?.value)
        XCTAssertEqual(originalSeries.last?.value, correctedSeries.last?.value)
        XCTAssertNotEqual(originalSeries[1].value, correctedSeries[1].value)
    }
}
