import XCTest
@testable import StockDeck

final class HoldingLotAggregationTests: XCTestCase {
    func testQuantityAndWeightedAverageAcrossPurchaseLots() {
        let lots = [
            Holding(symbol: "GOOG", quantity: 20, avgPrice: 170),
            Holding(symbol: "GOOG", quantity: 3, avgPrice: 299),
            Holding(symbol: "GOOG", quantity: 2, avgPrice: 303),
            Holding(symbol: "GOOG", quantity: 3, avgPrice: 334.26),
        ]

        XCTAssertEqual(HoldingLotAggregation.totalQuantity(lots), 28, accuracy: 1e-9)
        let weightedCost = 20.0 * 170.0 + 3.0 * 299.0 + 2.0 * 303.0 + 3.0 * 334.26
        let expectedAverage = weightedCost / 28.0
        XCTAssertEqual(
            HoldingLotAggregation.weightedAveragePrice(lots),
            expectedAverage,
            accuracy: 1e-9
        )
    }

    func testAverageUsesAbsoluteQuantityForShortLots() {
        let lots = [
            Holding(symbol: "X", quantity: -2, avgPrice: 100),
            Holding(symbol: "X", quantity: -1, avgPrice: 130),
        ]

        XCTAssertEqual(HoldingLotAggregation.totalQuantity(lots), -3, accuracy: 1e-9)
        XCTAssertEqual(HoldingLotAggregation.weightedAveragePrice(lots), 110, accuracy: 1e-9)
    }

    func testEmptyLotsReturnZero() {
        XCTAssertEqual(HoldingLotAggregation.totalQuantity([]), 0)
        XCTAssertEqual(HoldingLotAggregation.weightedAveragePrice([]), 0)
    }
}
